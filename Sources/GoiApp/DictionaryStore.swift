import AppKit
import Foundation
import MdictKit

struct DictFailure {
    let name: String
    let path: String
    let reason: String
}

final class LoadedDictionary {
    /// Content fingerprint of the MDX — stable across re-imports.
    let id: String
    /// Original title from the dictionary header / filename.
    let title: String
    /// What the UI shows — the user's alias when set (short names for tabs).
    var displayTitle: String
    let mdx: MdictFile
    let resources: [MdictFile]   // sibling MDD archives, in order (X.mdd, X.1.mdd, …)
    /// The dictionary's own directory inside the app library.
    let folder: URL
    /// lowercased basename -> URL for loose files beside the dictionary (css, images)
    let looseFiles: [String: URL]
    /// On-disk headword index; nil if it couldn't be built (falls back to
    /// MdictFile's in-memory lookup).
    let index: DictIndex?

    init(id: String, mdx: MdictFile, resources: [MdictFile], folder: URL, looseFiles: [String: URL], index: DictIndex?) {
        self.id = id
        self.mdx = mdx
        self.resources = resources
        self.folder = folder
        self.looseFiles = looseFiles
        self.index = index
        let headerTitle = mdx.header.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = headerTitle.isEmpty || headerTitle.lowercased() == "title (no html code allowed)"
            ? mdx.url.deletingPathExtension().lastPathComponent
            : headerTitle
        self.displayTitle = self.title
    }

    /// Cover image shipped alongside the dictionary (`<stem>.png/.jpg`), used
    /// as an icon. nil when the dictionary has none.
    lazy var iconURL: URL? = {
        let stem = mdx.url.deletingPathExtension().lastPathComponent
        for ext in ["png", "jpg", "jpeg"] {
            let candidate = folder.appendingPathComponent("\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }()

    /// Headword lookup — via the on-disk index if present (headwords may have
    /// been released from RAM), otherwise MdictFile's in-memory table.
    func lookup(_ word: String) -> [Int] {
        if let index { return index.lookup(norm: mdx.normalize(word)) }
        return mdx.lookup(word)
    }

    func suggest(prefix: String, limit: Int) -> [String] {
        if let index { return index.suggest(normPrefix: mdx.normalize(prefix), limit: limit) }
        return mdx.suggest(prefix: prefix, limit: limit)
    }

    /// Resolves a resource referenced from an entry: first the MDD archives,
    /// then loose files in the dictionary's folder.
    func resource(path raw: String) -> Data? {
        var decoded = raw.removingPercentEncoding ?? raw
        // dictionaries reference resources with a relative "./" (or ".\")
        // prefix; strip it so the MDD key resolves (\SPX\x.spx, not \.\SPX\…)
        while decoded.hasPrefix("./") || decoded.hasPrefix(".\\") { decoded.removeFirst(2) }
        var key = decoded.replacingOccurrences(of: "/", with: "\\")
        if !key.hasPrefix("\\") { key = "\\" + key }
        for mdd in resources {
            if let index = mdd.lookup(key).first {
                return try? mdd.record(at: index)
            }
        }
        // loose file fallback; refuse path traversal
        guard !decoded.contains("..") else { return nil }
        let direct = folder.appendingPathComponent(decoded.replacingOccurrences(of: "\\", with: "/"))
        if let data = try? Data(contentsOf: direct) { return data }
        let basename = (decoded as NSString).lastPathComponent.lowercased()
        if let url = looseFiles[basename] { return try? Data(contentsOf: url) }
        return nil
    }
}

/// The dictionary library lives inside the app container. Import clones the
/// user's files (APFS copy-on-write: zero extra space on the same volume),
/// so afterwards the originals can be moved or deleted freely — 「随便删，
/// 我有克隆」. Removing a dictionary here deletes only our clone.
final class DictionaryStore {
    private(set) var dictionaries: [LoadedDictionary] = []
    private(set) var failures: [DictFailure] = []
    private(set) var isReady = false

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Goi")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var dictionariesContainer: URL {
        let url = supportDirectory.appendingPathComponent("Dictionaries")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var reportURL: URL {
        supportDirectory.appendingPathComponent("词典解析报告.md")
    }

    // MARK: - Loading (scans the app library, not user folders)

    func loadAll(progress: @escaping (String) -> Void, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var loaded: [LoadedDictionary] = []
            var failed: [DictFailure] = []
            let fm = FileManager.default

            let subdirs = ((try? fm.contentsOfDirectory(
                at: Self.dictionariesContainer,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            for dir in subdirs {
                let entries = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
                )) ?? []
                guard let mdxURL = entries.first(where: {
                    $0.pathExtension.lowercased() == "mdx"
                        && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }) else {
                    failed.append(DictFailure(
                        name: dir.lastPathComponent, path: dir.path,
                        reason: "库目录中找不到 MDX 文件（导入可能中断过，可移除后重新添加）"
                    ))
                    continue
                }
                progress(mdxURL.deletingPathExtension().lastPathComponent)
                do {
                    let offsetsURL = dir.appendingPathComponent("goi-offsets.bin")
                    var mdx: MdictFile
                    var index: DictIndex?

                    // fast reopen: persisted offsets + a valid index → skip
                    // key-block parsing and keep no headword strings in RAM
                    if let savedOffsets = Self.loadOffsets(offsetsURL) {
                        let candidate = try MdictFile(url: mdxURL, keyOffsets: savedOffsets)
                        if let existing = DictIndex(openExistingIn: dir, expectedCount: candidate.entryCount) {
                            mdx = candidate
                            index = existing
                        } else {
                            // index stale/missing — full parse + rebuild
                            mdx = try MdictFile(url: mdxURL)
                            index = DictIndex(buildIn: dir, mdx: mdx)
                            Self.saveOffsets(mdx.keyRecordOffsets, to: offsetsURL)
                        }
                    } else {
                        mdx = try MdictFile(url: mdxURL)
                        index = DictIndex(buildIn: dir, mdx: mdx)
                        if index != nil { Self.saveOffsets(mdx.keyRecordOffsets, to: offsetsURL) }
                    }
                    var resources: [MdictFile] = []
                    let mdds = entries
                        .filter { $0.pathExtension.lowercased() == "mdd" }
                        .sorted {
                            $0.lastPathComponent.count < $1.lastPathComponent.count
                                || ($0.lastPathComponent.count == $1.lastPathComponent.count && $0.path < $1.path)
                        }
                    for mddURL in mdds {
                        do {
                            resources.append(try MdictFile(url: mddURL))
                        } catch {
                            failed.append(DictFailure(
                                name: mddURL.lastPathComponent, path: mddURL.path,
                                reason: "资源包暂时不可解析：\(error)"
                            ))
                        }
                    }
                    let id = Self.fingerprint(of: mdxURL) ?? dir.lastPathComponent
                    loaded.append(LoadedDictionary(
                        id: id, mdx: mdx, resources: resources,
                        folder: dir, looseFiles: Self.indexLooseFiles(in: dir), index: index
                    ))
                } catch {
                    failed.append(DictFailure(
                        name: mdxURL.lastPathComponent, path: mdxURL.path,
                        reason: "暂时不可解析：\(error)"
                    ))
                }
            }

            let aliases = UserDefaults.standard.dictionary(forKey: "dictionaryAliases") as? [String: String] ?? [:]
            for dict in loaded {
                if let alias = aliases[dict.id], !alias.isEmpty { dict.displayTitle = alias }
            }
            dictionaries = Self.applySavedOrder(to: loaded)
            failures = failed
            isReady = true
            writeReport()
            // headwords now live in each dictionary's on-disk index, so drop
            // the in-memory strings; only the compact record-offset arrays and
            // the mmap stay resident. Dictionaries without an index keep their
            // in-memory table as a fallback.
            for dict in loaded where dict.index != nil {
                dict.mdx.releaseKeyStrings()
            }
            completion()
        }
    }

    /// Record-offset sidecar: a little-endian UInt64 array. Lets a dictionary
    /// reopen without decompressing its key blocks.
    private static func loadOffsets(_ url: URL) -> [UInt64]? {
        guard let data = try? Data(contentsOf: url), data.count % 8 == 0, !data.isEmpty else { return nil }
        return data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt64.self)
            return (0..<buffer.count).map { UInt64(littleEndian: buffer[$0]) }
        }
    }

    private static func saveOffsets(_ offsets: [UInt64], to url: URL) {
        var data = Data(capacity: offsets.count * 8)
        for value in offsets {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        try? data.write(to: url)
    }

    private static func indexLooseFiles(in folder: URL) -> [String: URL] {
        var map: [String: URL] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var count = 0
        while let item = enumerator?.nextObject() as? URL {
            guard count < 5000 else { break } // image folders can be huge; basename map is a fallback only
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let ext = item.pathExtension.lowercased()
            guard !["mdx", "mdd"].contains(ext) else { continue }
            let base = item.lastPathComponent.lowercased()
            if map[base] == nil { map[base] = item }
            count += 1
        }
        return map
    }

    // MARK: - Import (clone into the library)

    struct ImportSummary {
        var imported: [String] = []
        var skippedDuplicates: [String] = []
        var failed: [(name: String, reason: String)] = []
    }

    /// Content fingerprint: FNV-1a over the first 256KB + file size.
    static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 262_144)) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in head {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        hash = (hash ^ UInt64(size)) &* 0x0000_0100_0000_01b3
        return String(format: "%016llx", hash)
    }

    /// Imports every MDX found under the given files/folders by cloning it
    /// (plus paired MDDs and loose resources) into the app library.
    func importDictionaries(
        from urls: [URL],
        progress: @escaping (String) -> Void,
        completion: @escaping (ImportSummary) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var summary = ImportSummary()

            var mdxFiles: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
                    while let item = enumerator?.nextObject() as? URL {
                        guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                        if item.pathExtension.lowercased() == "mdx" { mdxFiles.append(item) }
                    }
                } else if url.pathExtension.lowercased() == "mdx" {
                    mdxFiles.append(url)
                }
            }
            mdxFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

            var existing = Set(Self.libraryFingerprints())
            for mdx in mdxFiles {
                let name = mdx.deletingPathExtension().lastPathComponent
                progress(name)
                guard let fingerprint = Self.fingerprint(of: mdx) else {
                    summary.failed.append((name, "无法读取文件"))
                    continue
                }
                if existing.contains(fingerprint) {
                    summary.skippedDuplicates.append(name)
                    continue
                }
                do {
                    try Self.cloneDictionary(mdx: mdx, fingerprint: fingerprint)
                    existing.insert(fingerprint)
                    summary.imported.append(name)
                } catch {
                    summary.failed.append((name, "\(error)"))
                }
            }
            completion(summary)
        }
    }

    private static func libraryFingerprints() -> [String] {
        let fm = FileManager.default
        let subdirs = (try? fm.contentsOfDirectory(
            at: dictionariesContainer, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return subdirs.compactMap { dir in
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            guard let mdx = entries.first(where: { $0.pathExtension.lowercased() == "mdx" }) else { return nil }
            return fingerprint(of: mdx)
        }
    }

    /// Clones one dictionary into its own library directory. On the same
    /// APFS volume FileManager.copyItem uses clonefile: instant and free.
    private static func cloneDictionary(mdx: URL, fingerprint: String) throws {
        let fm = FileManager.default
        let stem = mdx.deletingPathExtension().lastPathComponent
        let safeStem = stem
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let destDir = dictionariesContainer.appendingPathComponent("\(safeStem)-\(fingerprint.prefix(8))")
        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir) // stale partial import
        }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        try fm.copyItem(at: mdx, to: destDir.appendingPathComponent(mdx.lastPathComponent))

        let sourceDir = mdx.deletingLastPathComponent()
        let siblings = (try? fm.contentsOfDirectory(
            at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for item in siblings {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let ext = item.pathExtension.lowercased()
            let dest = destDir.appendingPathComponent(item.lastPathComponent)
            if isDir {
                // resource folders only; a folder containing MDX/MDD is another dictionary
                if !containsMdict(item) { try? fm.copyItem(at: item, to: dest) }
            } else if ext == "mdd" {
                // X.mdx pairs with X.mdd, X.1.mdd, …
                var mddStem = item.deletingPathExtension().lastPathComponent
                if let range = mddStem.range(of: #"\.\d+$"#, options: .regularExpression) {
                    mddStem = String(mddStem[..<range.lowerBound])
                }
                if mddStem == stem { try fm.copyItem(at: item, to: dest) }
            } else if ext != "mdx" {
                try? fm.copyItem(at: item, to: dest) // loose css/js/images
            }
        }
    }

    private static func containsMdict(_ dir: URL) -> Bool {
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if ["mdx", "mdd"].contains(item.pathExtension.lowercased()) { return true }
        }
        return false
    }

    /// Removing = deleting our clone (drops the block references; the user's
    /// original files are untouched). The folder goes to Trash for safety.
    func removeFromLibrary(_ dict: LoadedDictionary, completion: @escaping (Error?) -> Void) {
        guard dict.folder.path.hasPrefix(Self.dictionariesContainer.path) else {
            completion(NSError(domain: "goi", code: 2, userInfo: [NSLocalizedDescriptionKey: "词典不在库目录内，拒绝删除"]))
            return
        }
        NSWorkspace.shared.recycle([dict.folder]) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    // MARK: - Search

    struct Section {
        let dict: LoadedDictionary
        let indices: [Int]
    }

    struct SearchResult {
        let query: String
        let banner: String?
        let sections: [Section]
        /// The word the sections actually show: the query itself, or the
        /// base form when lemma fallback kicked in. Nil when nothing matched.
        var resolvedWord: String?
        var isEmpty: Bool { sections.isEmpty }
    }

    func search(_ raw: String) -> SearchResult {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else {
            return SearchResult(query: raw, banner: nil, sections: [], resolvedWord: nil)
        }

        var sections = query(word)
        var banner: String?
        var resolved: String? = sections.isEmpty ? nil : word
        if sections.isEmpty {
            for candidate in Lemma.candidates(for: word) where candidate != word {
                sections = query(candidate)
                if !sections.isEmpty {
                    banner = "未找到「\(word)」，已按原型「\(candidate)」查询"
                    resolved = candidate
                    break
                }
            }
        }
        return SearchResult(query: word, banner: banner, sections: sections, resolvedWord: resolved)
    }

    private func query(_ word: String) -> [Section] {
        dictionaries.compactMap { dict in
            var seen = Set<Int>()
            var indices: [Int] = []
            for hit in dict.lookup(word) {
                var index = hit
                var hops = 0
                while hops < 5,
                      let text = try? dict.mdx.text(at: index),
                      text.hasPrefix("@@@LINK=") {
                    let target = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let next = dict.lookup(target).first else { break }
                    index = next
                    hops += 1
                }
                if seen.insert(index).inserted { indices.append(index) }
            }
            return indices.isEmpty ? nil : Section(dict: dict, indices: indices)
        }
    }

    func suggestions(for raw: String, limit: Int = 12) -> [String] {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for dict in dictionaries {
            for key in dict.suggest(prefix: word, limit: 4) {
                let display = key.trimmingCharacters(in: .whitespaces)
                if seen.insert(display.lowercased()).inserted { out.append(display) }
            }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    func dictionary(id: String) -> LoadedDictionary? {
        dictionaries.first { $0.id == id }
    }

    // MARK: - Display order & aliases

    private static let orderKey = "dictionaryOrder"

    /// Known dictionaries keep their saved rank; new ones append in load order.
    private static func applySavedOrder(to loaded: [LoadedDictionary]) -> [LoadedDictionary] {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        guard !saved.isEmpty else { return loaded }
        var rank: [String: Int] = [:]
        for (i, id) in saved.enumerated() { rank[id] = i }
        return loaded.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? saved.count + a.offset
                let rb = rank[b.element.id] ?? saved.count + b.offset
                return ra < rb
            }
            .map(\.element)
    }

    /// List-reorder semantics matching SwiftUI's onMove.
    func moveDictionaries(fromOffsets source: IndexSet, toOffset destination: Int) {
        var items = dictionaries
        let moving = source.sorted(by: >).map { items.remove(at: $0) }
        let adjusted = destination - source.count(where: { $0 < destination })
        items.insert(contentsOf: moving.reversed(), at: adjusted)
        dictionaries = items
        UserDefaults.standard.set(items.map(\.id), forKey: Self.orderKey)
    }

    /// Reorder to match `ids` (e.g. sorted by usage); unknown ids keep
    /// their relative position at the end.
    func applyOrder(ids: [String]) {
        var rank: [String: Int] = [:]
        for (i, id) in ids.enumerated() { rank[id] = i }
        dictionaries = dictionaries.enumerated()
            .sorted { a, b in
                (rank[a.element.id] ?? ids.count + a.offset) < (rank[b.element.id] ?? ids.count + b.offset)
            }
            .map(\.element)
        UserDefaults.standard.set(dictionaries.map(\.id), forKey: Self.orderKey)
    }

    /// Short alias for tabs; empty restores the original title.
    func setAlias(_ raw: String, for id: String) {
        guard let dict = dictionary(id: id) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var aliases = UserDefaults.standard.dictionary(forKey: "dictionaryAliases") as? [String: String] ?? [:]
        if trimmed.isEmpty || trimmed == dict.title {
            aliases.removeValue(forKey: id)
            dict.displayTitle = dict.title
        } else {
            aliases[id] = trimmed
            dict.displayTitle = trimmed
        }
        UserDefaults.standard.set(aliases, forKey: "dictionaryAliases")
    }

    // MARK: - Report

    private func writeReport() {
        var lines = [
            "# Goi 词典解析报告",
            "",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "词典库位置：`\(Self.dictionariesContainer.path)`",
            "（词典以 APFS 克隆方式导入，原始文件可随意移动或删除）",
            "",
            "## 已加载（\(dictionaries.count)）",
            "",
        ]
        for dict in dictionaries {
            let mdds = dict.resources.isEmpty ? "" : " + \(dict.resources.count) 个资源包"
            lines.append("- \(dict.title) — \(dict.mdx.entryCount) 词条\(mdds) (v\(dict.mdx.header.version), \(dict.mdx.header.codec.name))")
        }
        lines.append("")
        lines.append("## 失败（\(failures.count)）")
        lines.append("")
        if failures.isEmpty {
            lines.append("无。")
        } else {
            for failure in failures {
                lines.append("- **\(failure.name)**：\(failure.reason)")
                lines.append("  路径：`\(failure.path)`")
            }
        }
        lines.append("")
        lines.append("已知限制：MDX v3 与需注册码的加密词典（Encrypted&1）暂不支持；Speex/Ogg 音频暂不能播放。")
        if !Mecab.isAvailable {
            lines.append("")
            lines.append("提示：未检测到 mecab，日语变形还原（食べました→食べる）不可用。安装即生效：`brew install mecab mecab-ipadic`。")
        }
        try? lines.joined(separator: "\n").write(to: Self.reportURL, atomically: true, encoding: .utf8)
    }
}
