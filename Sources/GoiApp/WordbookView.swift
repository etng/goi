import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    let vocab: VocabStore
    var onSelect: (String) -> Void
    @State private var rows: [VocabStore.LogRow] = []
    @State private var page = 0
    @State private var total = 0
    private let pageSize = 50

    private var totalPages: Int { max(1, (total + pageSize - 1) / pageSize) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("查词历史").font(.headline)
                Text("\(total) 条").foregroundColor(.secondary).font(.subheadline)
                Spacer()
                Button {
                    page -= 1
                    load()
                } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0)
                Text("\(page + 1) / \(totalPages)").font(.system(size: 12)).monospacedDigit()
                Button {
                    page += 1
                    load()
                } label: { Image(systemName: "chevron.right") }
                    .disabled(page + 1 >= totalPages)
            }
            .padding(12)
            Divider()

            if rows.isEmpty {
                Spacer()
                Text("还没有查询记录").foregroundColor(.secondary)
                Spacer()
            } else {
                List(rows) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.surface).font(.system(size: 14, weight: .medium))
                            if row.lemma != row.surface {
                                Text("→ \(row.lemma)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(Self.sourceLabel(row.source))
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .foregroundColor(.secondary)
                        Text(Self.dateFormatter.string(from: row.ts))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(row.lemma) }
                    .help("点击查看（不计入查询次数）")
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
    }

    private func load() {
        total = vocab.historyCount()
        if page >= totalPages { page = max(0, totalPages - 1) }
        rows = vocab.history(offset: page * pageSize, limit: pageSize)
    }

    private static func sourceLabel(_ source: String) -> String {
        switch source {
        case "typed": return "键入"
        case "suggestion": return "候选"
        case "link": return "链接"
        default: return source
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

struct WordbookView: View {
    let vocab: VocabStore
    let store: DictionaryStore
    var onSelect: (String) -> Void = { _ in }
    @State private var rows: [VocabStore.WordRow] = []
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("生词本").font(.headline)
                Text("\(rows.count) 词").foregroundColor(.secondary).font(.subheadline)
                Spacer()
                Button("导入 JSON") { importJSON() }.disabled(busy)
                Button("导出 CSV") { exportCSV() }.disabled(busy || rows.isEmpty)
                Button("导出 JSON") { exportJSON() }.disabled(busy)
                Button("同步到 Anki") { pushToAnki() }.disabled(busy || rows.isEmpty)
                Button("从 Anki 回读") { pullFromAnki() }
                    .disabled(busy)
                    .help("读取 Anki 复习数据（间隔/难度），把确实记住的词的熟悉度调上去")
            }
            .padding(12)
            Divider()

            if rows.isEmpty {
                Spacer()
                Text("生词本还是空的\n查过 2 次的词会自动进来；查词面板里点 ☆ 手动加入")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.manual ? "star.fill" : "star")
                                .foregroundColor(row.manual ? .yellow : .secondary.opacity(0.4))
                                .help(row.manual ? "手动加入（高权重）" : "自动加入")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.lemma).font(.system(size: 14, weight: .medium))
                                if row.surfaces != row.lemma, !row.surfaces.isEmpty {
                                    Text(row.surfaces.replacingOccurrences(of: "\n", with: " · "))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(row.lemma) }
                            .help("点击查看（不计入查询次数）")
                            Spacer()
                            Text("\(row.lookupCount) 次")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            familiarityBadge(row)
                            if row.ankiNoteID != nil {
                                Image(systemName: "checkmark.icloud")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .help("已同步到 Anki")
                            }
                            Button {
                                vocab.deleteWord(lemma: row.lemma)
                                reload()
                            } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("从生词本删除")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            if !status.isEmpty {
                Divider()
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
    }

    private func familiarityBadge(_ row: VocabStore.WordRow) -> some View {
        let value = VocabStore.effectiveFamiliarity(of: row)
        let color: Color = value < 35 ? .red : (value < 70 ? .orange : .green)
        return Text(String(format: "%.0f", value))
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 30, alignment: .trailing)
            .help("熟悉度 0–100，越低越陌生")
    }

    private func reload() {
        rows = vocab.wordbook()
    }

    // MARK: - Actions

    private func exportCSV() {
        savePanel(name: "goi-wordbook.csv", type: .commaSeparatedText) { url in
            try? vocab.exportWordbookCSV().write(to: url)
            status = "已导出 CSV 到 \(url.path)"
        }
    }

    private func exportJSON() {
        savePanel(name: "goi-vocab.json", type: .json) { url in
            if let data = vocab.exportJSON() {
                try? data.write(to: url)
                status = "已导出全量数据（含查询历史）到 \(url.path)"
            }
        }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        do {
            let count = try vocab.importJSON(data)
            reload()
            status = "已合并导入 \(count) 个词（熟悉度取更陌生值）"
        } catch {
            status = "导入失败：\(error.localizedDescription)"
        }
    }

    private func pushToAnki() {
        busy = true
        status = "正在同步到 Anki…"
        let words = rows
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = words.map { row in
                (row: row, definition: definition(for: row.lemma))
            }
            do {
                let result = try AnkiClient.push(words: payload) { lemma, noteID in
                    vocab.setAnkiNoteID(noteID, lemma: lemma)
                }
                DispatchQueue.main.async {
                    busy = false
                    reload()
                    var text = "Anki 同步完成：新建 \(result.added) 张，更新 \(result.updated) 张"
                    if !result.failed.isEmpty {
                        text += "，失败 \(result.failed.count) 个（\(result.failed.prefix(2).joined(separator: "；"))…）"
                    }
                    status = text
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    status = "同步失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func pullFromAnki() {
        busy = true
        status = "正在读取 Anki 复习数据…"
        let words = rows
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stats = try AnkiClient.pullReviewStats()
                var raised = 0
                for row in words {
                    guard let stat = stats[row.lemma] else { continue }
                    let ankiValue = AnkiClient.familiarity(from: stat)
                    // one-directional for v0: Anki can only certify you KNOW a
                    // word better than our lookup counter thought
                    if ankiValue > VocabStore.effectiveFamiliarity(of: row) {
                        vocab.setFamiliarity(lemma: row.lemma, value: ankiValue, source: "anki")
                        raised += 1
                    }
                }
                DispatchQueue.main.async {
                    busy = false
                    reload()
                    status = stats.isEmpty
                        ? "Anki 里还没有 goi 标签的卡片（先「同步到 Anki」并复习一段时间）"
                        : "回读完成：\(stats.count) 张卡片，上调了 \(raised) 个词的熟悉度"
                }
            } catch {
                DispatchQueue.main.async {
                    busy = false
                    status = "回读失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// Plain-text definition from the highest-priority dictionary that has
    /// the word (Anki can't resolve goi:// resources, so tags are stripped).
    private func definition(for lemma: String) -> String {
        let result = store.search(lemma)
        guard let section = result.sections.first,
              let index = section.indices.first,
              let html = try? section.dict.mdx.text(at: index) else { return "" }
        var text = html
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(div|p|li|dd|dt)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, ch) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: ch)
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1200 { text = String(text.prefix(1200)) + "…" }
        return "【\(section.dict.displayTitle)】\n" + text
    }

    private func savePanel(name: String, type: UTType, then: (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }
}

extension Notification.Name {
    static let goiReloadRequested = Notification.Name("goi.reload.requested")
}

struct SettingsView: View {
    let store: DictionaryStore
    var onReorder: () -> Void
    @State private var items: [Row] = []
    @State private var mecabPath: String? = Mecab.path
    @State private var ankiStatus = "未检测"
    @State private var copied = false

    struct Row: Identifiable {
        let id: String
        let title: String
        let entries: Int
    }

    @State private var importing = false
    @State private var importStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ---- library ----
            VStack(alignment: .leading, spacing: 6) {
                Text("词典库").font(.headline)
                Text("词典以 APFS 克隆导入到 App 自己的库里（同卷零额外空间、瞬间完成）。导入后原始文件可随意移动或删除，互不影响。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if importing {
                        ProgressView().controlSize(.small)
                    }
                    Text(importStatus.isEmpty ? "库位置：\(DictionaryStore.dictionariesContainer.path)" : importStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("添加词典…") { addDictionaries() }
                        .disabled(importing)
                    Button("重新扫描") {
                        NotificationCenter.default.post(name: .goiReloadRequested, object: nil)
                    }
                    .disabled(importing)
                }
            }
            .padding(12)

            Divider()

            // ---- dependencies ----
            VStack(alignment: .leading, spacing: 8) {
                Text("依赖").font(.headline)
                HStack(spacing: 8) {
                    Image(systemName: mecabPath != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(mecabPath != nil ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("mecab — 日语变形还原（食べました→食べる）").font(.system(size: 12))
                        Text(mecabPath ?? "未安装：\(Mecab.installCommand)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if mecabPath == nil {
                        Button(copied ? "已复制" : "复制安装命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Mecab.installCommand, forType: .string)
                            copied = true
                        }
                    }
                    Button("重新检测") {
                        mecabPath = Mecab.path
                        copied = false
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "n.circle")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AnkiConnect — 生词本同步到 Anki").font(.system(size: 12))
                        Text(ankiStatus + (AnkiClient.apiKey != nil ? "（已自动读取 API key）" : ""))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("检测连接") {
                        ankiStatus = "检测中…"
                        DispatchQueue.global().async {
                            let status = AnkiClient.probe()
                            DispatchQueue.main.async { ankiStatus = status }
                        }
                    }
                }
            }
            .padding(12)

            Divider()

            // ---- dictionary order ----
            VStack(alignment: .leading, spacing: 6) {
                Text("词典顺序").font(.headline)
                Text("这里或查词页的 tab 条上都可以拖动排序；顺序即优先级（决定 tab 顺序、「全部」视图排列、Anki 释义来源）。tab 右键可设默认词典。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding([.top, .horizontal], 12)
            List {
                ForEach(items) { row in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary.opacity(0.5))
                        AliasField(row: row, store: store, onChanged: onReorder)
                        Spacer()
                        Text("\(row.entries) 词条")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .contextMenu {
                        Button("恢复原名") {
                            store.setAlias("", for: row.id)
                            reload()
                            onReorder()
                        }
                        Divider()
                        Button("从库中移除…", role: .destructive) {
                            removeDictionary(row)
                        }
                    }
                }
                .onMove { source, destination in
                    store.moveDictionaries(fromOffsets: source, toOffset: destination)
                    reload()
                    onReorder()
                }
            }
            .listStyle(.inset)
            Text("点铅笔改短别名（tab 显示用）；右键「从库中移除」只删 App 的克隆并释放引用，你的原始词典文件不受影响。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding([.horizontal, .bottom], 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
    }

    private func removeDictionary(_ row: Row) {
        guard let dict = store.dictionaries.first(where: { $0.id == row.id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "从库中移除「\(dict.displayTitle)」？"
        alert.informativeText = "只删除 App 库里的克隆（移到废纸篓，可恢复）。你自己下载的原始词典文件不受任何影响。\n\n库目录：\(dict.folder.lastPathComponent)"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeFromLibrary(dict) { error in
            if let error {
                let failure = NSAlert()
                failure.messageText = "移除失败"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            } else {
                NotificationCenter.default.post(name: .goiReloadRequested, object: nil)
            }
        }
    }

    private func addDictionaries() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入"
        panel.message = "选择 MDX 文件或包含词典的目录（如 ~/dicts），将以克隆方式导入词典库"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importing = true
        importStatus = "正在导入…"
        store.importDictionaries(from: panel.urls) { name in
            DispatchQueue.main.async { importStatus = "正在导入 \(name)…" }
        } completion: { summary in
            DispatchQueue.main.async {
                importing = false
                var parts = ["导入 \(summary.imported.count) 本"]
                if !summary.skippedDuplicates.isEmpty { parts.append("跳过重复 \(summary.skippedDuplicates.count) 本") }
                if !summary.failed.isEmpty { parts.append("失败 \(summary.failed.count) 本") }
                importStatus = parts.joined(separator: "，")
                NotificationCenter.default.post(name: .goiReloadRequested, object: nil)
                // never silent about failures
                if !summary.failed.isEmpty {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "\(summary.failed.count) 本词典导入失败"
                    alert.informativeText = summary.failed
                        .map { "· \($0.name)：\($0.reason)" }
                        .joined(separator: "\n")
                    alert.runModal()
                }
            }
        }
    }

    private func reload() {
        items = store.dictionaries.map {
            Row(id: $0.id, title: $0.displayTitle, entries: $0.mdx.entryCount)
        }
    }
}

/// Double-click the name to open a small editor popover for the tab alias.
private struct AliasField: View {
    let row: SettingsView.Row
    let store: DictionaryStore
    var onChanged: () -> Void
    @State private var showingEditor = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Text(row.title)
            .lineLimit(1)
            .contentShape(Rectangle())
            .help(originalTitle == row.title ? "双击改短别名（tab 显示用）" : "原名：\(originalTitle)（双击修改别名）")
            .onTapGesture(count: 2) {
                text = row.title
                showingEditor = true
            }
            .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("词典别名").font(.system(size: 12, weight: .semibold))
                    Text("原名：\(originalTitle)")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .lineLimit(2).frame(maxWidth: 260, alignment: .leading)
                    TextField("留空恢复原名", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .focused($focused)
                        .onSubmit(commit)
                    HStack {
                        Spacer()
                        Button("取消") { showingEditor = false }
                        Button("保存", action: commit).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
                .onAppear { focused = true }
            }
    }

    private var originalTitle: String {
        store.dictionaries.first { $0.id == row.id }?.title ?? row.title
    }

    private func commit() {
        store.setAlias(text, for: row.id)
        showingEditor = false
        onChanged()
    }
}
