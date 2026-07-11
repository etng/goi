import Foundation
import MdictKit

struct DictFailure {
    let name: String
    let path: String
    let reason: String
}

final class LoadedDictionary {
    let id: String
    let title: String
    let mdx: MdictFile
    let resources: [MdictFile]   // sibling MDD archives, in order (X.mdd, X.1.mdd, …)
    let folder: URL
    /// lowercased basename -> URL for loose files beside the dictionary (css, images)
    let looseFiles: [String: URL]

    init(mdx: MdictFile, resources: [MdictFile], folder: URL, looseFiles: [String: URL]) {
        self.mdx = mdx
        self.resources = resources
        self.folder = folder
        self.looseFiles = looseFiles
        let path = mdx.url.path
        self.id = String(format: "%08x", path.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 })
        let headerTitle = mdx.header.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = headerTitle.isEmpty || headerTitle.lowercased() == "title (no html code allowed)"
            ? mdx.url.deletingPathExtension().lastPathComponent
            : headerTitle
    }

    /// Resolves a resource referenced from an entry: first the MDD archives,
    /// then loose files in the dictionary's folder.
    func resource(path raw: String) -> Data? {
        let decoded = raw.removingPercentEncoding ?? raw
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

final class DictionaryStore {
    private(set) var dictionaries: [LoadedDictionary] = []
    private(set) var failures: [DictFailure] = []
    private(set) var isReady = false

    var rootURL: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "dictionaryRoot") {
                return URL(fileURLWithPath: path)
            }
            return URL(fileURLWithPath: NSHomeDirectory() + "/dicts")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "dictionaryRoot") }
    }

    static var reportURL: URL {
        supportDirectory.appendingPathComponent("词典解析报告.md")
    }

    static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Goi")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func loadAll(progress: @escaping (String) -> Void, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var loaded: [LoadedDictionary] = []
            var failed: [DictFailure] = []

            var mdxFiles: [URL] = []
            var mddFiles: [URL] = []
            let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: [.isRegularFileKey]
            )
            while let item = enumerator?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                switch item.pathExtension.lowercased() {
                case "mdx": mdxFiles.append(item)
                case "mdd": mddFiles.append(item)
                default: break
                }
            }
            mdxFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

            for url in mdxFiles {
                let name = url.deletingPathExtension().lastPathComponent
                progress(name)
                do {
                    let mdx = try MdictFile(url: url)
                    let folder = url.deletingLastPathComponent()
                    let siblings = Self.siblingMDDs(for: url, in: mddFiles)
                    var resources: [MdictFile] = []
                    for mddURL in siblings {
                        do {
                            resources.append(try MdictFile(url: mddURL))
                        } catch {
                            failed.append(DictFailure(
                                name: mddURL.lastPathComponent, path: mddURL.path,
                                reason: "资源包暂时不可解析：\(error)"
                            ))
                        }
                    }
                    let loose = Self.indexLooseFiles(in: folder)
                    loaded.append(LoadedDictionary(mdx: mdx, resources: resources, folder: folder, looseFiles: loose))
                } catch {
                    failed.append(DictFailure(
                        name: url.lastPathComponent, path: url.path,
                        reason: "暂时不可解析：\(error)"
                    ))
                }
            }

            dictionaries = Self.applySavedOrder(to: loaded)
            failures = failed
            isReady = true
            writeReport()
            // build MDX lookup tables up front (in parallel) so the first query
            // is instant; MDD resource tables build lazily on first media access
            DispatchQueue.concurrentPerform(iterations: loaded.count) { i in
                loaded[i].mdx.prepareIndex()
            }
            completion()
        }
    }

    /// X.mdx pairs with X.mdd, X.1.mdd, X.2.mdd … in the same directory.
    private static func siblingMDDs(for mdx: URL, in mddFiles: [URL]) -> [URL] {
        let stem = mdx.deletingPathExtension().lastPathComponent
        let dir = mdx.deletingLastPathComponent().path
        return mddFiles
            .filter { mdd in
                guard mdd.deletingLastPathComponent().path == dir else { return false }
                var mddStem = mdd.deletingPathExtension().lastPathComponent
                if let dot = mddStem.range(of: #"\.\d+$"#, options: .regularExpression) {
                    mddStem = String(mddStem[..<dot.lowerBound])
                }
                return mddStem == stem
            }
            .sorted { $0.lastPathComponent.count < $1.lastPathComponent.count
                || ($0.lastPathComponent.count == $1.lastPathComponent.count && $0.path < $1.path) }
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
            for hit in dict.mdx.lookup(word) {
                var index = hit
                var hops = 0
                while hops < 5,
                      let text = try? dict.mdx.text(at: index),
                      text.hasPrefix("@@@LINK=") {
                    let target = text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let next = dict.mdx.lookup(target).first else { break }
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
            for key in dict.mdx.suggest(prefix: word, limit: 4) {
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

    // MARK: - Display order

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

    // MARK: - Report

    private func writeReport() {
        var lines = [
            "# Goi 词典解析报告",
            "",
            "生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "词典目录：`\(rootURL.path)`",
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
