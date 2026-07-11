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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ---- dictionaries directory ----
            VStack(alignment: .leading, spacing: 6) {
                Text("词典目录").font(.headline)
                HStack {
                    Text(store.rootURL.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("更换…") { chooseRoot() }
                    Button("重新加载") {
                        NotificationCenter.default.post(name: .goiReloadRequested, object: nil)
                    }
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
                        Button("删除词典（移到废纸篓）…", role: .destructive) {
                            deleteDictionary(row)
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
            Text("双击名称可改短别名（tab 显示用）；右键可删除词典——文件会移到废纸篓，可随时找回。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding([.horizontal, .bottom], 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
    }

    private func deleteDictionary(_ row: Row) {
        guard let dict = store.dictionaries.first(where: { $0.id == row.id }) else { return }
        let files = dict.fileURLs
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除词典「\(dict.displayTitle)」？"
        alert.informativeText = "以下 \(files.count) 个文件将移到废纸篓（可从废纸篓恢复）：\n"
            + files.map { "· \($0.lastPathComponent)" }.joined(separator: "\n")
            + "\n\n词典目录里的 CSS/图片等散文件不会被动。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle(files) { _, error in
            DispatchQueue.main.async {
                if let error {
                    let failure = NSAlert()
                    failure.messageText = "删除失败"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                } else {
                    NotificationCenter.default.post(name: .goiReloadRequested, object: nil)
                }
            }
        }
    }

    private func chooseRoot() {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.directoryURL = store.rootURL
        dialog.prompt = "使用此目录"
        dialog.message = "选择存放 MDX/MDD 词典的目录"
        if dialog.runModal() == .OK, let url = dialog.url {
            store.rootURL = url
            NotificationCenter.default.post(name: .goiReloadRequested, object: nil)
        }
    }

    private func reload() {
        items = store.dictionaries.map {
            Row(id: $0.id, title: $0.displayTitle, entries: $0.mdx.entryCount)
        }
    }
}

/// Inline rename: double-click to edit, Enter/blur commits the alias.
private struct AliasField: View {
    let row: SettingsView.Row
    let store: DictionaryStore
    var onChanged: () -> Void
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        if editing {
            TextField("", text: $text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 260)
                .onExitCommand { editing = false }
        } else {
            Text(row.title)
                .lineLimit(1)
                .help(originalTitle == row.title ? "双击改短别名" : "原名：\(originalTitle)（双击修改别名）")
                .onTapGesture(count: 2) {
                    text = row.title
                    editing = true
                }
        }
    }

    private var originalTitle: String {
        store.dictionaries.first { $0.id == row.id }?.title ?? row.title
    }

    private func commit() {
        store.setAlias(text, for: row.id)
        editing = false
        onChanged()
    }
}
