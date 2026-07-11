import SwiftUI
import WebKit

extension Notification.Name {
    static let goiPanelShown = Notification.Name("goi.panel.shown")
}

final class SearchViewModel: ObservableObject {
    let store: DictionaryStore
    @Published var query = ""
    @Published var suggestions: [String] = []
    @Published private(set) var html: String
    private(set) var htmlVersion = 0

    private var debounce: DispatchWorkItem?
    private var suppressLiveSearch = false

    init(store: DictionaryStore) {
        self.store = store
        self.html = EntryHTML.welcomePage(loadedCount: 0, failureCount: 0, loading: true)
        self.htmlVersion = 1
    }

    private func setHTML(_ html: String) {
        self.html = html
        htmlVersion += 1
    }

    func showWelcome() {
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
            setHTML(EntryHTML.resultsPage(result: result))
        }
    }

    /// Return pressed: search now; fall back to the first suggestion.
    func submit() {
        debounce?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, store.isReady else { return }
        var result = store.search(q)
        if result.isEmpty, let first = suggestions.first {
            search(first)
            return
        }
        if result.isEmpty { result = store.search(q) }
        suggestions = []
        setHTML(EntryHTML.resultsPage(result: result))
    }

    /// Programmatic search (suggestion click, entry:// link).
    func search(_ word: String) {
        suppressLiveSearch = true
        query = word
        guard store.isReady else { return }
        let result = store.search(word)
        suggestions = result.isEmpty ? store.suggestions(for: word) : []
        setHTML(EntryHTML.resultsPage(result: result))
    }
}

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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if !model.suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.suggestions, id: \.self) { suggestion in
                            Button {
                                model.search(suggestion)
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
        .frame(width: 720, height: 600)
        .onReceive(NotificationCenter.default.publisher(for: .goiPanelShown)) { _ in
            focused = true
        }
        .onChange(of: model.query) { _ in model.queryChanged() }
    }
}

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
            webView.setValue(false, forKey: "drawsBackground") // let SwiftUI background show through
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
