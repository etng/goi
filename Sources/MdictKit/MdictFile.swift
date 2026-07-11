import Foundation

/// A parsed MDX dictionary or MDD resource archive.
///
/// Opening a file parses the header, the full key table, and the record-block
/// index. Record content is decompressed lazily, one block at a time.
public final class MdictFile {
    public struct KeyEntry {
        public let key: String
        public let recordOffset: UInt64
    }

    public let url: URL
    public let header: MdictHeader
    // hot-path copies of header flags (header attribute access is a dictionary lookup)
    private let lowercasesKeys: Bool
    private let stripsKeys: Bool

    // Key table split in two: the compact record-offset array is always kept
    // (record access needs it), while the headword strings — the memory hog
    // for large dictionaries — can be released once an external index (the
    // app's SQLite) has captured them. See releaseKeyStrings().
    public private(set) var keyRecordOffsets: [UInt64] = []
    private var keyStrings: [String] = []

    public var entryCount: Int { keyRecordOffsets.count }
    public var isResource: Bool { header.isResource }

    /// The full key table (headword + offset). O(n); for tools/indexing, not
    /// hot paths. Empty strings if headwords were released.
    public var keys: [KeyEntry] {
        (0..<keyRecordOffsets.count).map {
            KeyEntry(key: $0 < keyStrings.count ? keyStrings[$0] : "", recordOffset: keyRecordOffsets[$0])
        }
    }

    /// Headword at a key index (empty if released). Cheap, for indexing.
    public func keyString(at index: Int) -> String {
        index < keyStrings.count ? keyStrings[index] : ""
    }

    /// Streams every (headword, keyIndex) pair to `body`, for building an
    /// external index without materializing a `[KeyEntry]` array.
    public func forEachKey(_ body: (String, Int) -> Void) {
        for i in 0..<keyStrings.count { body(keyStrings[i], i) }
    }

    /// Drops the in-memory headword strings and exact-lookup table, keeping
    /// only what record access needs. Call after an external index has the
    /// headwords; afterwards lookup()/suggest() return nothing.
    public func releaseKeyStrings() {
        lookupTableLock.lock()
        defer { lookupTableLock.unlock() }
        keyStrings = []
        _lookupTable = nil
        _collisions = []
    }

    // record section
    private var recordCompSizes: [Int] = []
    private var recordDecompSizes: [Int] = []
    private var recordCompOffsets: [Int] = []    // relative to recordDataStart
    private var recordDecompOffsets: [UInt64] = []
    private var recordDataStart = 0
    private var totalDecompSize: UInt64 = 0

    private let data: Data
    private let lookupTableLock = NSLock()
    // Compact exact-lookup index: value >= 0 is a key index; value < 0 points
    // into `collisions` at -(value+1). Avoids one heap array per headword.
    private var _lookupTable: [String: Int]?
    private var _collisions: [[Int]] = []
    private lazy var sortedRecordOffsets: [UInt64] = {
        var offsets = Set(keyRecordOffsets)
        offsets.insert(totalDecompSize)
        return offsets.sorted()
    }()
    private var cachedBlock: (index: Int, content: Data)?

    /// Opens a dictionary. When `keyOffsets` is supplied (from a previously
    /// persisted index), the keyword blocks are skipped entirely — no
    /// decompression, no headword strings — which is the fast, low-memory
    /// reopen path. Pass nil for a full parse (needed to build the index).
    public init(url: URL, keyOffsets: [UInt64]? = nil) throws {
        self.url = url
        self.data = try Data(contentsOf: url, options: .alwaysMapped)

        var reader = DataReader(data)

        // ---- header ----
        let headerLength = Int(try reader.u32be())
        let headerBytes = try reader.bytes(headerLength)
        let headerChecksum = try reader.u32le() // little-endian, unlike everything else
        guard Adler32.checksum(headerBytes) == headerChecksum else {
            throw MdictError.badChecksum("header")
        }
        guard var xml = String(data: headerBytes, encoding: .utf16LittleEndian) else {
            throw MdictError.corrupted("header is not UTF-16LE")
        }
        xml = xml.trimmingCharacters(in: CharacterSet(charactersIn: "\0\u{FEFF}"))
        let isMDD = url.pathExtension.lowercased() == "mdd"
        header = try MdictHeader(xml: xml, isResource: isMDD)
        lowercasesKeys = !header.keyCaseSensitive
        stripsKeys = header.stripKey

        if header.encrypted & 1 != 0 {
            throw MdictError.unsupportedFeature("record encryption (Encrypted & 1) requires a registration code")
        }

        let v2 = header.version >= 2.0
        let numWidth = v2 ? 8 : 4

        // ---- keyword section ----
        let sectionStart = reader.pos
        let numKeyBlocks = Int(try reader.number(width: numWidth))
        let declaredEntries = Int(try reader.number(width: numWidth))
        if v2 { _ = try reader.number(width: 8) } // key index decompressed length
        let keyIndexLength = Int(try reader.number(width: numWidth))
        let keyBlocksLength = Int(try reader.number(width: numWidth))
        var keyIndexDecompLength = keyIndexLength // v1: index is stored raw
        if v2 {
            let headerEnd = reader.pos
            let checksum = try reader.u32be()
            var check = DataReader(data, at: sectionStart)
            let raw = try check.bytes(headerEnd - sectionStart)
            guard Adler32.checksum(raw) == checksum else {
                throw MdictError.badChecksum("keyword section header")
            }
            var again = DataReader(data, at: sectionStart + 16)
            keyIndexDecompLength = Int(try again.u64be())
        }

        // fast reopen: offsets come from the persisted index, skip the whole
        // keyword-block section (no decompression, no strings)
        if let keyOffsets, keyOffsets.count == declaredEntries {
            _ = keyIndexDecompLength
            try reader.skip(keyIndexLength + keyBlocksLength)
            keyRecordOffsets = keyOffsets
            try parseRecordSection(&reader, numWidth: numWidth)
            return
        }

        var keyIndex = try reader.bytes(keyIndexLength)
        if v2 {
            if header.encrypted & 2 != 0 {
                keyIndex = MdictBlock.decryptKeyIndex(keyIndex)
            }
            keyIndex = try MdictBlock.decompress(keyIndex, decompressedSize: keyIndexDecompLength)
        }
        let blockSizes = try Self.parseKeyIndex(
            keyIndex, blockCount: numKeyBlocks, codec: header.codec, v2: v2
        )

        // ---- key blocks ----
        let keyBlocksStart = reader.pos
        var offset = keyBlocksStart
        keyStrings.reserveCapacity(declaredEntries)
        keyRecordOffsets.reserveCapacity(declaredEntries)
        for (comp, decomp) in blockSizes {
            var blockReader = DataReader(data, at: offset)
            let block = try MdictBlock.decompress(try blockReader.bytes(comp), decompressedSize: decomp)
            try parseKeyBlock(block, offsetWidth: numWidth)
            offset += comp
        }
        guard offset - keyBlocksStart == keyBlocksLength else {
            throw MdictError.corrupted("key blocks length mismatch")
        }
        guard keyRecordOffsets.count == declaredEntries else {
            throw MdictError.corrupted("parsed \(keyRecordOffsets.count) keys, header declares \(declaredEntries)")
        }
        reader.pos = offset
        try parseRecordSection(&reader, numWidth: numWidth)
    }

    // MARK: - Parsing helpers

    private func parseRecordSection(_ reader: inout DataReader, numWidth: Int) throws {
        let numRecordBlocks = Int(try reader.number(width: numWidth))
        _ = try reader.number(width: numWidth) // total entries, equals key count
        let recordIndexLength = Int(try reader.number(width: numWidth))
        let recordBlocksLength = Int(try reader.number(width: numWidth))

        recordCompSizes.reserveCapacity(numRecordBlocks)
        recordDecompSizes.reserveCapacity(numRecordBlocks)
        var compOffset = 0
        var decompOffset: UInt64 = 0
        for _ in 0..<numRecordBlocks {
            let comp = Int(try reader.number(width: numWidth))
            let decomp = Int(try reader.number(width: numWidth))
            recordCompOffsets.append(compOffset)
            recordDecompOffsets.append(decompOffset)
            recordCompSizes.append(comp)
            recordDecompSizes.append(decomp)
            compOffset += comp
            decompOffset += UInt64(decomp)
        }
        totalDecompSize = decompOffset
        guard recordIndexLength == numRecordBlocks * numWidth * 2 else {
            throw MdictError.corrupted("record index length mismatch")
        }
        recordDataStart = reader.pos
        guard recordDataStart + recordBlocksLength <= data.count else {
            throw MdictError.truncated("record blocks extend past end of file")
        }
        guard compOffset == recordBlocksLength else {
            throw MdictError.corrupted("record blocks length mismatch")
        }
    }

    /// Returns (compressedSize, decompressedSize) for each key block.
    private static func parseKeyIndex(
        _ index: Data, blockCount: Int, codec: TextCodec, v2: Bool
    ) throws -> [(comp: Int, decomp: Int)] {
        var r = DataReader(index)
        let numWidth = v2 ? 8 : 4
        let term = v2 ? codec.terminatorWidth : 0
        var sizes: [(Int, Int)] = []
        sizes.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            _ = try r.number(width: numWidth) // entries in this block
            var head = v2 ? Int(try r.u16be()) : Int(try r.u8())
            if codec.sizesAreCodeUnits { head *= 2 }
            try r.skip(head + term)
            var tail = v2 ? Int(try r.u16be()) : Int(try r.u8())
            if codec.sizesAreCodeUnits { tail *= 2 }
            try r.skip(tail + term)
            let comp = Int(try r.number(width: numWidth))
            let decomp = Int(try r.number(width: numWidth))
            sizes.append((comp, decomp))
        }
        return sizes
    }

    private func parseKeyBlock(_ block: Data, offsetWidth: Int) throws {
        let bytes = [UInt8](block)
        let termWidth = header.codec.terminatorWidth
        var i = 0
        while i < bytes.count {
            guard i + offsetWidth <= bytes.count else {
                throw MdictError.corrupted("key block truncated at offset field")
            }
            var recordOffset: UInt64 = 0
            for _ in 0..<offsetWidth {
                recordOffset = recordOffset << 8 | UInt64(bytes[i])
                i += 1
            }
            var j = i
            if termWidth == 2 {
                while j + 1 < bytes.count, !(bytes[j] == 0 && bytes[j + 1] == 0) { j += 2 }
            } else {
                while j < bytes.count, bytes[j] != 0 { j += 1 }
            }
            let keyData = Data(bytes[i..<j])
            guard let key = header.codec.decode(keyData) else {
                throw MdictError.corrupted("undecodable key at block offset \(i)")
            }
            keyStrings.append(key)
            keyRecordOffsets.append(recordOffset)
            i = min(j + termWidth, bytes.count)
        }
    }

    // MARK: - Lookup

    /// Normalizes a key the way the dictionary's builder sorted it.
    public func normalize(_ key: String) -> String {
        if isResource {
            return key.lowercased().replacingOccurrences(of: "/", with: "\\")
        }
        // fast path: keys made only of CJK-zone scalars have no case and
        // contain none of the strippable (ASCII) characters — return as-is
        // without allocating. This makes indexing CJK dictionaries ~free.
        var untouched = true
        for scalar in key.unicodeScalars where scalar.value < 0x2E80 {
            untouched = false
            break
        }
        if untouched { return key }
        // second fast path: check whether any transform would actually apply
        // before paying for lowercased()/filter allocations. ASCII-only case
        // detection: non-ASCII case folding is skipped consistently on both
        // stored keys and queries, so the table stays self-consistent.
        var needsLower = false
        var needsStrip = false
        for u in key.utf8 {
            if lowercasesKeys, u >= 65, u <= 90 { needsLower = true }
            if stripsKeys, u < 0x80, Self.strippableASCII[Int(u)] { needsStrip = true }
            if needsLower, needsStrip { break }
        }
        if !needsLower, !needsStrip { return key }
        var k = key
        if needsLower { k = k.lowercased() }
        if needsStrip {
            var kept = String.UnicodeScalarView()
            for scalar in k.unicodeScalars
            where scalar.value >= 0x80 || !Self.strippableASCII[Int(scalar.value)] {
                kept.append(scalar)
            }
            k = String(kept)
        }
        return k
    }

    private static let strippableASCII: [Bool] = {
        var table = [Bool](repeating: false, count: 128)
        for ch in strippable {
            if let ascii = ch.asciiValue { table[Int(ascii)] = true }
        }
        return table
    }()

    private static let strippable = Set<Character>(
        " \t\r\n_=,.;:!?@%&#~`()[]<>{}/\\$+-*^'\"|"
    )

    private func ensureLookupTable() {
        lookupTableLock.lock()
        defer { lookupTableLock.unlock() }
        guard _lookupTable == nil else { return }
        var table = [String: Int](minimumCapacity: keyStrings.count)
        var collisions: [[Int]] = []
        for (i, key) in keyStrings.enumerated() {
            let norm = normalize(key)
            if let existing = table[norm] {
                if existing >= 0 {
                    collisions.append([existing, i])
                    table[norm] = -collisions.count
                } else {
                    collisions[-existing - 1].append(i)
                }
            } else {
                table[norm] = i
            }
        }
        _lookupTable = table
        _collisions = collisions
    }

    /// Indices into `keys` matching the given word (after normalization).
    public func lookup(_ word: String) -> [Int] {
        ensureLookupTable()
        guard let value = _lookupTable![normalize(word)] else { return [] }
        return value >= 0 ? [value] : _collisions[-value - 1]
    }

    /// Builds the exact-lookup hash table now instead of on first use.
    /// Safe to call from any thread; call once per file from a background
    /// queue to keep the first query instant.
    public func prepareIndex() {
        ensureLookupTable()
    }

    /// Best-effort prefix completion. Keys are stored in the order the
    /// dictionary builder sorted them, which for well-formed MDX files is
    /// the normalized key order — good enough for suggestions, not lookup.
    public func suggest(prefix: String, limit: Int) -> [String] {
        let p = normalize(prefix)
        guard !p.isEmpty, limit > 0 else { return [] }
        var lo = 0
        var hi = keyStrings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if normalize(keyStrings[mid]) < p { lo = mid + 1 } else { hi = mid }
        }
        var out: [String] = []
        var i = lo
        while i < keyStrings.count, out.count < limit {
            guard normalize(keyStrings[i]).hasPrefix(p) else { break }
            if out.last != keyStrings[i] { out.append(keyStrings[i]) }
            i += 1
        }
        return out
    }

    // MARK: - Record access

    public func record(at keyIndex: Int) throws -> Data {
        let start = keyRecordOffsets[keyIndex]
        // entry ends at the next distinct record offset, or at end of data
        var lo = 0, hi = sortedRecordOffsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedRecordOffsets[mid] <= start { lo = mid + 1 } else { hi = mid }
        }
        let end = lo < sortedRecordOffsets.count ? sortedRecordOffsets[lo] : totalDecompSize

        guard let blockIndex = recordDecompOffsets.lastIndex(where: { $0 <= start }) else {
            throw MdictError.corrupted("record offset \(start) before first block")
        }
        let blockStart = recordDecompOffsets[blockIndex]
        let blockEnd = blockStart + UInt64(recordDecompSizes[blockIndex])
        guard start < blockEnd else {
            throw MdictError.corrupted("record offset \(start) past end of data")
        }
        let clampedEnd = min(end, blockEnd)

        let content = try decompressedRecordBlock(blockIndex)
        let base = content.startIndex
        return content.subdata(in: (base + Int(start - blockStart))..<(base + Int(clampedEnd - blockStart)))
    }

    /// Record content decoded as text (MDX only).
    public func text(at keyIndex: Int) throws -> String {
        var record = try record(at: keyIndex)
        // strip trailing null terminator(s)
        while let last = record.last, last == 0 { record = record.dropLast() }
        if header.codec.terminatorWidth == 2, record.count % 2 == 1 { record.append(0) }
        guard let text = header.codec.decode(record) else {
            throw MdictError.corrupted("undecodable record for key #\(keyIndex)")
        }
        return text
    }

    private func decompressedRecordBlock(_ index: Int) throws -> Data {
        if let cached = cachedBlock, cached.index == index { return cached.content }
        let start = recordDataStart + recordCompOffsets[index]
        var r = DataReader(data, at: start)
        let block = try r.bytes(recordCompSizes[index])
        let content = try MdictBlock.decompress(block, decompressedSize: recordDecompSizes[index])
        cachedBlock = (index, content)
        return content
    }
}
