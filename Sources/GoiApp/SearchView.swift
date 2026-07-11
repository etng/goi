import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let goiPanelShown = Notification.Name("goi.panel.shown")
}

enum PanelSection: String, CaseIterable {
    case search
    case history
    case wordbook
    case stats
    case settings
    case about

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .history: return "clock"
        case .wordbook: return "star"
        case .stats: return "chart.bar"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }

    var label: String {
        switch self {
        case .search: return "查词"
        case .history: return "历史"
        case .wordbook: return "生词本"
        case .stats: return "统计"
        case .settings: return "设置"
        case .about: return "关于"
        }
    }
}

struct DictTab: Identifiable, Equatable {
    let id: String          // "" = 全部
    let title: String
    let hits: Int
}

final class SearchViewModel: ObservableObject {
    let store: DictionaryStore
    let vocab: VocabStore
    @Published var section: PanelSection = .search
    @Published var query = ""
    @Published var suggestions: [String] = []
    @Published var tabs: [DictTab] = []
    @Published var selectedTab = ""          // dictionary id, "" = 全部
    @Published var defaultTab: String? = UserDefaults.standard.string(forKey: "defaultTabID")
    @Published var inWordbook = false
    @Published var comments: [VocabStore.CommentRow] = []
    @Published private(set) var html: String
    private(set) var htmlVersion = 0
    private(set) var lastResult: DictionaryStore.SearchResult?

    private var debounce: DispatchWorkItem?
    private var suppressLiveSearch = false

    init(store: DictionaryStore, vocab: VocabStore) {
        self.store = store
        self.vocab = vocab
        self.html = EntryHTML.welcomePage(loadedCount: 0, failureCount: 0, loading: true)
        self.htmlVersion = 1
    }

    private func setHTML(_ html: String) {
        self.html = html
        htmlVersion += 1
    }

    func showWelcome() {
        lastResult = nil
        tabs = []
        setHTML(EntryHTML.welcomePage(
            loadedCount: store.dictionaries.count,
            failureCount: store.failures.count,
            loading: !store.isReady
        ))
    }

    func queryChanged() {
        if suppressLiveSearch {
            suppressLiveSearch = false
            return
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.liveSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func liveSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            suggestions = []
            showWelcome()
            return
        }
        guard store.isReady else { return }
        let result = store.search(q)
        if result.isEmpty {
            suggestions = store.suggestions(for: q)
        } else {
            suggestions = []
            render(result)
        }
    }

    /// Return pressed: search now; fall back to the first suggestion.
    func submit() {
        debounce?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, store.isReady else { return }
        let result = store.search(q)
        if result.isEmpty, let first = suggestions.first {
            search(first, source: "suggestion")
            return
        }
        suggestions = []
        logLookup(result, source: "typed")
        render(result)
    }

    /// Programmatic search (suggestion click, entry:// link).
    func search(_ word: String, source: String = "link") {
        suppressLiveSearch = true
        query = word
        guard store.isReady else { return }
        let result = store.search(word)
        suggestions = result.isEmpty ? store.suggestions(for: word) : []
        logLookup(result, source: source)
        render(result)
    }

    /// Look up text grabbed from another app (划词取词), recording the source
    /// sentence as context for the wordbook / Anki example.
    func lookupSelection(_ text: String, context: String?) {
        section = .search
        suppressLiveSearch = true
        query = text
        guard store.isReady else { return }
        let result = store.search(text)
        suggestions = result.isEmpty ? store.suggestions(for: text) : []
        if !result.isEmpty, let lemma = result.resolvedWord {
            vocab.recordLookup(surface: result.query, lemma: lemma, source: "selection", context: context)
            vocab.recordHits(dictIDs: result.sections.map { $0.dict.id })
            inWordbook = vocab.isInWordbook(lemma: lemma)
        }
        render(result)
    }

    /// Follow an in-entry cross-reference link. The link target may be an
    /// internal numeric key; query with it but show/record the readable
    /// anchor text the user actually clicked.
    func followLink(target rawTarget: String, label rawLabel: String) {
        section = .search
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = rawLabel.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n«»→\u{300A}\u{300B}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let display = label.isEmpty ? target : label
        suppressLiveSearch = true
        query = display
        guard store.isReady else { return }
        let raw = store.search(target)
        // present everything (search box, stats, notes, history) under the
        // readable word, while the sections come from querying the real target
        let shown = DictionaryStore.SearchResult(
            query: display, banner: raw.banner, sections: raw.sections,
            resolvedWord: raw.isEmpty ? nil : display
        )
        suggestions = raw.isEmpty ? store.suggestions(for: target) : []
        logLookup(shown, source: "link")
        render(shown)
    }

    /// Jump to a word from history/wordbook — display only, no weight change.
    func browse(_ word: String) {
        section = .search
        suppressLiveSearch = true
        query = word
        guard store.isReady else { return }
        let result = store.search(word)
        suggestions = result.isEmpty ? store.suggestions(for: word) : []
        inWordbook = result.resolvedWord.map { vocab.isInWordbook(lemma: $0) } ?? false
        render(result)
    }

    /// Re-render the current result (e.g. after a comment was added elsewhere).
    func refreshCurrent() {
        renderCurrent()
    }

    // MARK: - Tabs

    private func render(_ result: DictionaryStore.SearchResult) {
        lastResult = result
        let hitIDs = Set(result.sections.map(\.dict.id))
        // selection priority: current tab if it still hits, then the user's
        // default tab, then the first dictionary (in display order) with a
        // hit; 全部 only when nothing matched anywhere.
        if selectedTab != "", hitIDs.contains(selectedTab) {
            // keep
        } else if let preferred = defaultTab, hitIDs.contains(preferred) {
            selectedTab = preferred
        } else if let first = store.dictionaries.first(where: { hitIDs.contains($0.id) }) {
            selectedTab = first.id
        } else {
            selectedTab = ""
        }
        rebuildTabs()
        renderCurrent()
    }

    /// User clicked a tab (strip or overflow menu) — this is what counts
    /// as actually *using* a dictionary in the stats.
    func selectTab(_ id: String) {
        selectedTab = id
        if id != "", lastResult != nil {
            vocab.recordTabUse(dictID: id)
        }
        renderCurrent()
    }

    func setDefaultTab(_ id: String?) {
        defaultTab = id
        UserDefaults.standard.set(id, forKey: "defaultTabID")
    }

    /// Reorder by dragging a tab over another one.
    func moveTab(draggingID: String, over targetID: String) {
        guard draggingID != targetID, targetID != "", draggingID != "",
              let from = store.dictionaries.firstIndex(where: { $0.id == draggingID }),
              let to = store.dictionaries.firstIndex(where: { $0.id == targetID }) else { return }
        store.moveDictionaries(
            fromOffsets: IndexSet(integer: from),
            toOffset: to > from ? to + 1 : to
        )
        orderChanged()
    }

    /// Re-apply after the dictionary order changes.
    func orderChanged() {
        guard let q = lastResult?.query, !q.isEmpty else {
            rebuildTabs()
            return
        }
        render(store.search(q))
    }

    private func rebuildTabs() {
        guard let result = lastResult else {
            tabs = []
            return
        }
        let counts = Dictionary(uniqueKeysWithValues: result.sections.map { ($0.dict.id, $0.indices.count) })
        var list = [DictTab(id: "", title: "全部", hits: counts.values.reduce(0, +))]
        for dict in store.dictionaries {
            list.append(DictTab(id: dict.id, title: dict.displayTitle, hits: counts[dict.id] ?? 0))
        }
        tabs = list
    }

    private func renderCurrent() {
        guard let result = lastResult else {
            comments = []
            return
        }
        // the user's own record for this word: stats (in-page) + comments (native bar)
        let info = result.resolvedWord.flatMap { vocab.info(lemma: $0) }
        comments = result.resolvedWord.map { vocab.comments(lemma: $0) } ?? []
        if selectedTab == "" {
            setHTML(EntryHTML.resultsPage(result: result, wordInfo: info))
        } else {
            let filtered = DictionaryStore.SearchResult(
                query: result.query,
                banner: result.banner,
                sections: result.sections.filter { $0.dict.id == selectedTab },
                resolvedWord: result.resolvedWord
            )
            setHTML(EntryHTML.resultsPage(result: filtered, wordInfo: info))
        }
    }

    func addComment(_ text: String) {
        guard let lemma = currentLemma else { return }
        vocab.addComment(lemma: lemma, content: text)
        comments = vocab.comments(lemma: lemma)
    }

    // MARK: - Vocabulary

    /// The lemma the current result actually displays (after base-form fallback).
    var currentLemma: String? {
        guard let result = lastResult, !result.sections.isEmpty else { return nil }
        return result.resolvedWord
    }

    private func logLookup(_ result: DictionaryStore.SearchResult, source: String) {
        guard !result.isEmpty, let lemma = result.resolvedWord else {
            inWordbook = false
            return
        }
        vocab.recordLookup(surface: result.query, lemma: lemma, source: source)
        vocab.recordHits(dictIDs: result.sections.map { $0.dict.id })
        inWordbook = vocab.isInWordbook(lemma: lemma)
    }

    func toggleWordbook() {
        guard let lemma = currentLemma else { return }
        if inWordbook {
            vocab.removeFromWordbook(lemma: lemma)
        } else {
            vocab.addManually(lemma: lemma, surface: lastResult?.query ?? lemma)
        }
        inWordbook = vocab.isInWordbook(lemma: lemma)
    }
}

// MARK: - Root layout: left ribbon + section content

struct RootView: View {
    @ObservedObject var model: SearchViewModel

    var body: some View {
        content
            .frame(minWidth: 820, minHeight: 520)
    }

    private var isDev: Bool { (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(PanelSection.allCases, id: \.self) { section in
                    Button {
                        model.section = section
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: section.icon).font(.system(size: 16))
                            Text(section.label).font(.system(size: 9))
                        }
                        .frame(width: 44, height: 44)
                        .background(
                            model.section == section ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundColor(model.section == section ? .accentColor : .secondary)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(section.label)
                }
                Spacer()
                // app identity anchored at the ribbon's bottom-left
                VStack(spacing: 1) {
                    Text("語").font(.system(size: 15, weight: .medium))
                    Text(isDev ? "Goi ᴅ" : "Goi").font(.system(size: 8))
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 2)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 5)

            Divider()

            switch model.section {
            case .search:
                SearchView(model: model)
            case .history:
                HistoryView(vocab: model.vocab) { [weak model] word in model?.browse(word) }
            case .wordbook:
                WordbookView(vocab: model.vocab, store: model.store) { [weak model] word in
                    model?.browse(word)
                }
            case .stats:
                StatsView(vocab: model.vocab, store: model.store) { [weak model] in
                    model?.orderChanged()
                }
            case .settings:
                SettingsView(store: model.store, vocab: model.vocab) { [weak model] in model?.orderChanged() }
            case .about:
                AboutView()
            }
        }
    }
}


// MARK: - Search section

struct SearchView: View {
    @ObservedObject var model: SearchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
                TextField("查词 · 回车搜索 · Esc 关闭", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .light))
                    .focused($focused)
                    .onSubmit { model.submit() }
                if model.currentLemma != nil {
                    Button {
                        model.toggleWordbook()
                    } label: {
                        Image(systemName: model.inWordbook ? "star.fill" : "star")
                            .font(.system(size: 17))
                            .foregroundColor(model.inWordbook ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.inWordbook ? "移出生词本" : "加入生词本（高权重）")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if !model.tabs.isEmpty {
                TabStrip(model: model)
                Divider()
            }

            if !model.suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.suggestions, id: \.self) { suggestion in
                            Button {
                                model.search(suggestion, source: "suggestion")
                            } label: {
                                HStack {
                                    Text(suggestion).font(.system(size: 14))
                                    Spacer()
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
                Divider()
            }

            ResultsWebView(model: model)

            if model.currentLemma != nil {
                NotesBar(model: model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goiPanelShown)) { _ in
            focused = true
        }
        .onChange(of: model.query) { _ in model.queryChanged() }
    }
}

/// Fixed "我的心得" region pinned to the bottom of the search view — the
/// signature user-facing feature, always visible and quick to reach.
struct NotesBar: View {
    @ObservedObject var model: SearchViewModel
    @State private var draft = ""
    @State private var expanded = true
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "lightbulb").font(.system(size: 12)).foregroundColor(.orange)
                Text("我的心得").font(.system(size: 12, weight: .semibold))
                if !model.comments.isEmpty {
                    Text("\(model.comments.count)").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.03))

            if expanded {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("记录你对这个词的理解、联想、例句…（⌘↩ 保存）", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .focused($editing)
                    Button("保存", action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                if !model.comments.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.comments) { comment in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.dateFormatter.string(from: comment.ts))
                                        .font(.system(size: 10)).foregroundColor(.secondary)
                                    Text(comment.content)
                                        .font(.system(size: 13))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .background(.regularMaterial)
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addComment(text)
        draft = ""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

// MARK: - Dictionary tabs (click to filter, drag to reorder, right-click for default)

struct TabStrip: View {
    @ObservedObject var model: SearchViewModel
    @State private var dragging: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(model.tabs) { tab in
                        tabView(tab)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onDrop(of: [.text], isTargeted: nil) { _ in
                dragging = nil
                return true
            }

            // overflow picker: full dictionary list when the strip can't fit
            Menu {
                ForEach(model.tabs) { tab in
                    Button {
                        model.selectTab(tab.id)
                    } label: {
                        let mark = model.selectedTab == tab.id ? "✓ " : ""
                        Text("\(mark)\(tab.title)\(tab.hits > 0 ? "（\(tab.hits)）" : "")")
                    }
                    .disabled(tab.hits == 0 && tab.id != "")
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("全部词典（宽度不够时从这里选）")
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder
    private func tabView(_ tab: DictTab) -> some View {
        let unavailable = tab.hits == 0 && tab.id != ""
        let selected = model.selectedTab == tab.id
        let isDefault = model.defaultTab == tab.id && tab.id != ""

        let label = HStack(spacing: 4) {
            if isDefault {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150)
            if tab.hits > 0 {
                Text("\(tab.hits)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: Capsule())
        .foregroundColor(
            unavailable ? Color.secondary.opacity(0.4) : (selected ? .accentColor : .primary)
        )
        .contentShape(Capsule())
        .opacity(dragging == tab.id ? 0.35 : 1)
        .onTapGesture {
            if !unavailable { model.selectTab(tab.id) }
        }

        if tab.id == "" {
            label
        } else {
            label
                .onDrag {
                    dragging = tab.id
                    return NSItemProvider(object: tab.id as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(
                    target: tab.id, dragging: $dragging, model: model
                ))
                .contextMenu {
                    if isDefault {
                        Button("取消默认词典") { model.setDefaultTab(nil) }
                    } else {
                        Button("设为默认词典") { model.setDefaultTab(tab.id) }
                    }
                    Button("排到最前") {
                        model.moveTab(draggingID: tab.id, over: model.store.dictionaries.first?.id ?? tab.id)
                    }
                }
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let model: SearchViewModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        model.moveTab(draggingID: dragging, over: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Results web view

struct ResultsWebView: NSViewRepresentable {
    @ObservedObject var model: SearchViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVersion != model.htmlVersion else { return }
        context.coordinator.loadedVersion = model.htmlVersion
        webView.loadHTMLString(model.html, baseURL: URL(string: "goi://d/main")!)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let model: SearchViewModel
        var loadedVersion = -1

        lazy var webView: WKWebView = {
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(GoiSchemeHandler(store: model.store), forURLScheme: "goi")
            config.userContentController.add(WeakMessageHandler(self), name: "goi")
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.setValue(false, forKey: "drawsBackground")
            return webView
        }()

        init(model: SearchViewModel) {
            self.model = model
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "goi",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "entry":
                if let word = body["word"] as? String, !word.isEmpty {
                    model.followLink(target: word, label: body["label"] as? String ?? "")
                }
            case "sound":
                guard let dictID = body["dict"] as? String,
                      let path = body["path"] as? String,
                      let dict = model.store.dictionary(id: dictID) else { return }
                let ext = (path as NSString).pathExtension.lowercased()
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let data = dict.resource(path: path)
                    let result = data.map { AudioPlayer.shared.play($0, ext: ext) } ?? .failed
                    DispatchQueue.main.async {
                        let reason: String?
                        switch result {
                        case .played: reason = nil
                        case .failed: reason = data == nil ? "找不到音频资源" : "音频解码失败"
                        case .unsupported(let e):
                            reason = "\(e) 音频需要解码器：\(AudioPlayer.decoderInstallHint)"
                        }
                        if let reason { self?.webView.evaluateJavaScript("goiToast(\"\(reason)\")") }
                    }
                }
            default:
                break
            }
        }
    }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
