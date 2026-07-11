import Foundation

/// A compressed MDX/MDD block: 4-byte compression type, 4-byte big-endian
/// adler32 of the *decompressed* content, then the payload.
enum MdictBlock {
    static func decompress(_ block: Data, decompressedSize: Int, verifyChecksum: Bool = true) throws -> Data {
        guard block.count >= 8 else { throw MdictError.truncated("block shorter than 8 bytes") }
        let base = block.startIndex
        let type = block[base]
        var r = DataReader(block, at: 4)
        let checksum = try r.u32be()
        let payload = block.subdata(in: (base + 8)..<(base + block.count))

        let out: Data
        switch type {
        case 0:
            out = payload
        case 1:
            out = try LZO.decompress(payload, decompressedSize: decompressedSize)
        case 2:
            out = try Zlib.decompress(payload, decompressedSize: decompressedSize)
        default:
            throw MdictError.unsupportedFeature("unknown block compression type \(type)")
        }
        guard out.count == decompressedSize else {
            throw MdictError.corrupted("block decompressed to \(out.count), expected \(decompressedSize)")
        }
        if verifyChecksum {
            guard Adler32.checksum(out) == checksum else {
                throw MdictError.badChecksum("block content adler32 mismatch")
            }
        }
        return out
    }

    /// In-place decryption of an MDX key index whose header declares Encrypted & 2.
    static func decryptKeyIndex(_ block: Data) -> Data {
        let base = block.startIndex
        var keySeed = [UInt8](block.subdata(in: (base + 4)..<(base + 8)))
        keySeed.append(contentsOf: [0x95, 0x36, 0x00, 0x00]) // 0x3695 little-endian
        let key = RIPEMD128.hash(keySeed)

        var body = [UInt8](block.subdata(in: (base + 8)..<(base + block.count)))
        var previous: UInt8 = 0x36
        for i in 0..<body.count {
            var t = (body[i] >> 4) | (body[i] << 4)
            t ^= previous
            t ^= UInt8(i & 0xff)
            t ^= key[i % key.count]
            previous = body[i]
            body[i] = t
        }

        var result = block.subdata(in: base..<(base + 8))
        result.append(contentsOf: body)
        return result
    }
}
