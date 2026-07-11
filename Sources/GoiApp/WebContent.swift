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
        body { margin: 8px 12px; font-family: -apple-system; background: #fff; }
        </style>
        <script>
        const DICT_ID = "\(dict.id)";
        document.addEventListener("click", function (e) {
            const a = e.target.closest("a");
            if (!a) return;
            const href = a.getAttribute("href") || "";
            if (href.startsWith("entry://")) {
                e.preventDefault();
                let word = decodeURIComponent(href.slice(8)).split("#")[0];
                if (word) webkit.messageHandlers.goi.postMessage({ type: "entry", word: word });
            } else if (href.startsWith("sound://")) {
                e.preventDefault();
                webkit.messageHandlers.goi.postMessage({ type: "sound", dict: DICT_ID, path: href.slice(8) });
            } else if (href.indexOf("://") === -1 && href && !href.startsWith("#")) {
                // bare href — MDX convention for a cross-reference
                e.preventDefault();
                webkit.messageHandlers.goi.postMessage({ type: "entry", word: decodeURIComponent(href).split("#")[0] });
            }
        }, true);
        </script>
        </head><body>\(body)</body></html>
        """
    }

    /// The aggregated results page: one collapsible section per dictionary,
    /// entries embedded as same-origin iframes so per-dictionary CSS can't clash.
    /// `wordInfo`/`comments` surface the user's own history for this lemma.
    static func resultsPage(
        result: DictionaryStore.SearchResult,
        wordInfo: VocabStore.WordRow? = nil,
        comments: [VocabStore.CommentRow] = []
    ) -> String {
        var sections = ""
        if let banner = result.banner {
            sections += #"<div class="banner">\#(escape(banner))</div>"#
        }
        if let info = wordInfo {
            let familiarity = String(format: "%.0f", VocabStore.effectiveFamiliarity(of: info))
            var parts = ["已查 \(info.lookupCount) 次", "熟悉度 \(familiarity)"]
            if info.inWordbook { parts.append(info.manual ? "★ 生词本（手动）" : "★ 生词本") }
            if !comments.isEmpty { parts.append("心得 \(comments.count) 条") }
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
        if let lemma = result.resolvedWord {
            let items = comments.map { comment in
                #"<li><span class="note-time">\#(shortDate(comment.ts))</span><div class="note-body">\#(escape(comment.content))</div></li>"#
            }.joined()
            sections += """
            <details class="notes" open><summary>我的心得<span class="count" id="noteCount">\(comments.count)</span></summary>
            <div class="note-input">
              <textarea id="noteText" rows="2" placeholder="记录你对「\(escape(lemma))」的理解、联想、例句…"></textarea>
              <button onclick="goiSaveNote()">保存</button>
            </div>
            <ul id="noteList">\(items)</ul>
            </details>
            <script>
            const GOI_LEMMA = \(jsString(lemma));
            function goiSaveNote() {
                const box = document.getElementById("noteText");
                const value = box.value.trim();
                if (!value) return;
                webkit.messageHandlers.goi.postMessage({ type: "comment", lemma: GOI_LEMMA, text: value });
                const li = document.createElement("li");
                const time = document.createElement("span");
                time.className = "note-time";
                time.textContent = "刚刚";
                const body = document.createElement("div");
                body.className = "note-body";
                body.textContent = value;
                li.append(time, body);
                document.getElementById("noteList").prepend(li);
                const count = document.getElementById("noteCount");
                count.textContent = (parseInt(count.textContent) || 0) + 1;
                box.value = "";
            }
            </script>
            """
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
        body { margin: 0; padding: 6px 10px 14px; font-family: -apple-system; background: #f6f6f8; }
        .banner { background: #fff8e1; border: 1px solid #e6d9a0; border-radius: 6px;
                  padding: 6px 10px; margin: 6px 0; font-size: 13px; }
        .wordmeta { color: #777; font-size: 12px; padding: 4px 2px; }
        .notes .note-input { display: flex; gap: 8px; padding: 8px 10px; }
        .notes textarea { flex: 1; resize: vertical; font: 13px -apple-system;
                          border: 1px solid #ddd; border-radius: 6px; padding: 6px 8px; }
        .notes button { align-self: flex-end; font-size: 12px; padding: 4px 14px; }
        .notes ul { list-style: none; margin: 0; padding: 0 10px 8px; }
        .notes li { border-top: 1px solid #eee; padding: 6px 2px; }
        .note-time { color: #aaa; font-size: 11px; margin-right: 8px; }
        .note-body { font-size: 13px; white-space: pre-wrap; margin-top: 2px; }
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
        } else {
            status = "已加载 \(loadedCount) 本词典" + (failureCount > 0 ? "，<b>\(failureCount) 本暂时不可解析</b>（详见菜单栏 → 解析报告）" : "")
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

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast()) // ["..."] -> "..."
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
