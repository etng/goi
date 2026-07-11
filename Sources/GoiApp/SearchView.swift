import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let goiPanelShown = Notification.Name("goi.panel.shown")
}

enum PanelSection: String, CaseIterable {
    case search
    case wordbook
    case settings
    case about

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .wordbook: return "star"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }

    var label: String {
        switch self {
        case .search: return "查词"
        case .wordbook: return "生词本"
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
        render(result)
        logLookup(result, source: "typed")
    }

    /// Programmatic search (suggestion click, entry:// link).
    func search(_ word: String, source: String = "link") {
        suppressLiveSearch = true
        query = word
        guard store.isReady else { return }
        let result = store.search(word)
        suggestions = result.isEmpty ? store.suggestions(for: word) : []
        render(result)
        logLookup(result, source: source)
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

    func selectTab(_ id: String) {
        selectedTab = id
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
            list.append(DictTab(id: dict.id, title: dict.title, hits: counts[dict.id] ?? 0))
        }
        tabs = list
    }

    private func renderCurrent() {
        guard let result = lastResult else { return }
        if selectedTab == "" {
            setHTML(EntryHTML.resultsPage(result: result))
        } else {
            let filtered = DictionaryStore.SearchResult(
                query: result.query,
                banner: result.banner,
                sections: result.sections.filter { $0.dict.id == selectedTab },
                resolvedWord: result.resolvedWord
            )
            setHTML(EntryHTML.resultsPage(result: filtered))
        }
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
        VStack(spacing: 0) {
            HeaderBar(model: model)
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 480)
    }

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
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 5)

            Divider()

            switch model.section {
            case .search:
                SearchView(model: model)
            case .wordbook:
                WordbookView(vocab: model.vocab, store: model.store)
            case .settings:
                SettingsView(store: model.store) { [weak model] in model?.orderChanged() }
            case .about:
                AboutView()
            }
        }
    }
}

/// Title-bar strip: identity + status, and the window's only drag handle.
struct HeaderBar: View {
    @ObservedObject var model: SearchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 62) // clear the traffic-light buttons
            Text("語 Goi")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(model.section.label)
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.65))
            Spacer()
            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .contentShape(Rectangle())
        .background(WindowDragArea())
    }

    private var statusText: String {
        if !model.store.isReady { return "正在加载词典…" }
        var text = "\(model.store.dictionaries.count) 本词典"
        if !model.store.failures.isEmpty { text += " · \(model.store.failures.count) 本不可解析" }
        return text
    }
}

/// Lets the header act as the window drag region.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .goiPanelShown)) { _ in
            focused = true
        }
        .onChange(of: model.query) { _ in model.queryChanged() }
    }
}

// MARK: - Dictionary tabs (click to filter, drag to reorder, right-click for default)

struct TabStrip: View {
    @ObservedObject var model: SearchViewModel
    @State private var dragging: String?

    var body: some View {
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
                    model.search(word)
                }
            case "sound":
                guard let dictID = body["dict"] as? String,
                      let path = body["path"] as? String,
                      let dict = model.store.dictionary(id: dictID) else { return }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let data = dict.resource(path: path)
                    DispatchQueue.main.async {
                        let played = data.map { AudioPlayer.shared.play($0) } ?? false
                        if !played {
                            let ext = (path as NSString).pathExtension.lowercased()
                            let reason = data == nil ? "找不到音频资源" : "暂不支持的音频格式：\(ext)"
                            self?.webView.evaluateJavaScript("goiToast(\"\(reason)\")")
                        }
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
