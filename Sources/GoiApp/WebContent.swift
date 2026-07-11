import Foundation
import WebKit

/// Serves goi:// URLs to the results WKWebView. Everything lives under the
/// single host "d" so the results page and entry iframes share one origin
/// (required for the iframe height sync in the results page).
///
///   goi://d/entry/<dictID>/<index>       wrapped entry HTML (loaded in an iframe)
///   goi://d/entry/<dictID>/<any path>    resource relative to an entry (css/img/…)
final class GoiSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: DictionaryStore
    private let lock = NSLock()
    private var active = Set<ObjectIdentifier>()

    init(store: DictionaryStore) {
        self.store = store
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        lock.lock(); active.insert(id); lock.unlock()

        guard let url = task.request.url else {
            finish(task, id: id, data: nil, mime: "text/plain")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let (data, mime) = serve(url)
            DispatchQueue.main.async {
                self.finish(task, id: id, data: data, mime: mime)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); active.remove(ObjectIdentifier(task)); lock.unlock()
    }

    private func finish(_ task: WKURLSchemeTask, id: ObjectIdentifier, data: Data?, mime: String) {
        lock.lock()
        let alive = active.remove(id) != nil
        lock.unlock()
        guard alive else { return }
        guard let data, let url = task.request.url else {
            task.didFailWithError(NSError(domain: "goi", code: 404))
            return
        }
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func serve(_ url: URL) -> (Data?, String) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.host == "d", parts.count >= 3, parts[0] == "entry",
              let dict = store.dictionary(id: parts[1]) else {
            return (nil, "text/plain")
        }
        if parts.count == 3, let index = Int(parts[2]), index < dict.mdx.entryCount {
            let html = EntryHTML.entryPage(dict: dict, index: index)
            return (Data(html.utf8), "text/html")
        }
        // anything else under entry/<dictID>/ is a resource reference
        let rest = parts.dropFirst(2).joined(separator: "/")
        if let data = dict.resource(path: rest) {
            return (data, Self.mimeType(for: rest))
        }
        return (nil, "text/plain")
    }

    static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "wav": return "audio/wav"
        case "ogg", "spx": return "audio/ogg"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }
}

enum EntryHTML {
    /// Wraps one dictionary entry for display inside an iframe.
    static func entryPage(dict: LoadedDictionary, index: Int) -> String {
        let body = (try? dict.mdx.text(at: index)) ?? "<p>词条读取失败</p>"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
        /* some dictionaries hardcode a huge body height (e.g. 英汉大词典's
           2000px "回到顶部" scaffold) — neutralize it or the iframe grows
           a screenful of blank space */
        html, body { height: auto !important; min-height: 0 !important; }
        /* entries keep their native light styling — dictionary CSS is authored
           for a white background, and inverting it wrecks colors/contrast.
           In dark mode the entry sits as a white card on the dark canvas. */
        body { margin: 8px 12px; font-family: -apple-system; background: #fff; color: #111; }
        /* contain dictionaries whose CSS overflows horizontally (e.g. 明鏡's
           related-word rows): wrap long content, cap media/tables to the
           width, and let genuinely wide tables scroll inside themselves
           instead of stretching the whole entry */
        html { overflow-x: hidden; }
        body { overflow-wrap: anywhere; word-break: break-word; }
        img, svg, video { max-width: 100%; height: auto; }
        table { max-width: 100%; display: block; overflow-x: auto; }
        </style>
        <script>
        const DICT_ID = "\(dict.id)";
        document.addEventListener("click", function (e) {
            const a = e.target.closest("a");
            if (!a) return;
            const href = a.getAttribute("href") || "";
            const label = (a.textContent || "").trim();
            if (href.startsWith("entry://")) {
                e.preventDefault();
                let word = decodeURIComponent(href.slice(8)).split("#")[0];
                if (word) webkit.messageHandlers.goi.postMessage({ type: "entry", word: word, label: label });
            } else if (href.startsWith("sound://")) {
                e.preventDefault();
                webkit.messageHandlers.goi.postMessage({ type: "sound", dict: DICT_ID, path: href.slice(8) });
            } else if (href.indexOf("://") === -1 && href && !href.startsWith("#")) {
                // bare href — MDX convention for a cross-reference
                e.preventDefault();
                webkit.messageHandlers.goi.postMessage({ type: "entry", word: decodeURIComponent(href).split("#")[0], label: label });
            }
        }, true);
        </script>
        </head><body>\(body)</body></html>
        """
    }

    /// The aggregated results page: one collapsible section per dictionary,
    /// entries embedded as same-origin iframes so per-dictionary CSS can't clash.
    /// `wordInfo` surfaces the user's own lookup record; comments render in a
    /// native bar below the web view.
    static func resultsPage(
        result: DictionaryStore.SearchResult,
        wordInfo: VocabStore.WordRow? = nil
    ) -> String {
        var sections = ""
        if let banner = result.banner {
            sections += #"<div class="banner">\#(escape(banner))</div>"#
        }
        if let info = wordInfo {
            let familiarity = String(format: "%.0f", VocabStore.effectiveFamiliarity(of: info))
            var parts = ["已查 \(info.lookupCount) 次", "熟悉度 \(familiarity)"]
            if info.inWordbook { parts.append(info.manual ? "★ 生词本（手动）" : "★ 生词本") }
            parts.append("首查 \(shortDate(info.firstSeen))")
            sections += #"<div class="wordmeta">\#(escape(parts.joined(separator: " · ")))</div>"#
        }
        if result.isEmpty {
            sections += #"<div class="empty">没有词典收录「\#(escape(result.query))」</div>"#
        }
        for section in result.sections {
            let frames = section.indices.map {
                #"<iframe loading="lazy" src="goi://d/entry/\#(section.dict.id)/\#($0)"></iframe>"#
            }.joined()
            sections += """
            <details open><summary>\(escape(section.dict.displayTitle))\
            <span class="count">\(section.indices.count)</span></summary>\(frames)</details>
            """
        }
        // notes live in a native fixed bar below the web view, not here
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
        body { margin: 0; padding: 6px 10px 14px; font-family: -apple-system; background: #f6f6f8; }
        .banner { background: #fff8e1; border: 1px solid #e6d9a0; border-radius: 6px;
                  padding: 6px 10px; margin: 6px 0; font-size: 13px; }
        .wordmeta { color: #777; font-size: 12px; padding: 4px 2px; }
        .empty { color: #888; text-align: center; padding: 48px 0; font-size: 14px; }
        details { background: #fff; border: 1px solid #ddd; border-radius: 8px;
                  margin: 8px 0; overflow: hidden; }
        summary { padding: 7px 12px; font-weight: 600; font-size: 13px; cursor: pointer;
                  background: #efeff2; user-select: none; }
        summary .count { float: right; color: #999; font-weight: 400; }
        iframe { display: block; width: 100%; border: 0; height: 100px; background: #fff; }
        #toast { position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%);
                 background: rgba(40,40,40,.92); color: #fff; padding: 7px 16px;
                 border-radius: 16px; font-size: 12px; display: none; z-index: 9; }
        /* dark mode dresses the chrome only — the entry iframe stays a white
           card so dictionary content renders as designed */
        @media (prefers-color-scheme: dark) {
            body { background: #1c1c1e; }
            .banner { background: #3a3320; border-color: #5c5330; color: #e8dca0; }
            .empty { color: #8a8a8e; }
            .wordmeta { color: #98989d; }
            details { background: #2c2c2e; border-color: #3a3a3c; }
            summary { background: #363638; color: #e5e5e7; }
            details .count { color: #8a8a8e; }
            iframe { background: #fff; }
        }
        </style>
        <script>
        function goiToast(msg) {
            const t = document.getElementById("toast");
            t.textContent = msg; t.style.display = "block";
            clearTimeout(t._timer);
            t._timer = setTimeout(() => t.style.display = "none", 2600);
        }
        // same-origin iframes: keep heights in sync with their content
        setInterval(function () {
            document.querySelectorAll("iframe").forEach(function (f) {
                try {
                    const h = f.contentDocument.documentElement.scrollHeight;
                    if (h > 20 && Math.abs(h - f.clientHeight) > 6) f.style.height = h + "px";
                } catch (e) {}
            });
        }, 350);
        </script>
        </head><body>\(sections)<div id="toast"></div></body></html>
        """
    }

    static func welcomePage(loadedCount: Int, failureCount: Int, loading: Bool) -> String {
        let status: String
        if loading {
            status = "正在加载词典…"
        } else if loadedCount == 0 && failureCount == 0 {
            status = "词典库是空的<br>到左侧 设置 → 添加词典… 选择你下载的 MDX 文件或目录<br>（克隆导入，不占额外空间，导入后原文件随意处置）"
        } else if failureCount > 0 {
            status = "输入即可查词<br><b>\(failureCount) 本词典暂时不可解析</b>（详见菜单栏 → 解析报告）"
        } else {
            status = "输入即可查词 · \(HotKeyStore.selection.label) 划词"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin:0; font-family:-apple-system; background:#f6f6f8; color:#777;
               display:flex; align-items:center; justify-content:center; height:100vh; }
        div { text-align:center; font-size:14px; line-height:2; }
        </style></head><body><div>語彙 Goi<br>\(status)</div></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
