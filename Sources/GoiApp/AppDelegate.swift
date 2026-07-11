import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DictionaryStore()
    private var vocab: VocabStore!
    private var model: SearchViewModel!
    private var panel: SearchPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        vocab = VocabStore(url: DictionaryStore.supportDirectory.appendingPathComponent("vocab.sqlite3"))
        model = SearchViewModel(store: store, vocab: vocab)
        panel = SearchPanel(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "語"
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Goi — ⌥Space 查词"
        }

        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.panel.toggle()
        }

        NotificationCenter.default.addObserver(
            forName: .goiReloadRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.loadDictionaries()
        }

        loadDictionaries()
    }

    private func loadDictionaries() {
        statusItem.button?.appearsDisabled = true
        store.loadAll(progress: { _ in }) { [weak self] in
            DispatchQueue.main.async { self?.dictionariesLoaded() }
        }
    }

    private func dictionariesLoaded() {
        statusItem.button?.appearsDisabled = false
        model.showWelcome()

        // in-app dependency prompt (not just a line in the report)
        if !Mecab.isAvailable, !UserDefaults.standard.bool(forKey: "mecabPromptDismissed") {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "未检测到 mecab"
            alert.informativeText = "日语变形还原（食べました→食べる）需要 mecab。\n\n在终端运行：\n\(Mecab.installCommand)\n\n装好后在设置里点「重新检测」即生效，无需重启。"
            alert.addButton(withTitle: "复制安装命令")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "不再提醒")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Mecab.installCommand, forType: .string)
            case .alertThirdButtonReturn:
                UserDefaults.standard.set(true, forKey: "mecabPromptDismissed")
            default:
                break
            }
        }

        // never silent: parse failures get an explicit prompt
        if !store.failures.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(store.failures.count) 本词典暂时不可解析"
            alert.informativeText = store.failures
                .map { "· \($0.name)" }
                .joined(separator: "\n")
                + "\n\n其余 \(store.dictionaries.count) 本已正常加载。详细原因见解析报告。"
            alert.addButton(withTitle: "打开解析报告")
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(DictionaryStore.reportURL)
            }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // restore left-click behavior
        } else {
            panel.toggle()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status: String
        if !store.isReady {
            status = "正在加载词典…"
        } else if store.failures.isEmpty {
            status = "已加载 \(store.dictionaries.count) 本词典"
        } else {
            status = "已加载 \(store.dictionaries.count) 本，\(store.failures.count) 本暂不可解析"
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        if !store.failures.isEmpty {
            let failuresMenu = NSMenu()
            for failure in store.failures {
                let item = NSMenuItem(title: failure.name, action: nil, keyEquivalent: "")
                item.toolTip = failure.reason
                item.isEnabled = false
                failuresMenu.addItem(item)
            }
            let parent = NSMenuItem(title: "暂不可解析的词典", action: nil, keyEquivalent: "")
            menu.addItem(parent)
            menu.setSubmenu(failuresMenu, for: parent)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "打开查词面板  ⌥Space", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "生词本", action: #selector(openWordbook), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开解析报告", action: #selector(openReport), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "重新加载词典", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Goi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openWordbook() { panel.show(section: .wordbook) }

    @objc private func openSettings() { panel.show(section: .settings) }

    @objc private func showPanel() { panel.show() }

    @objc private func openReport() { NSWorkspace.shared.open(DictionaryStore.reportURL) }

    @objc private func reload() { loadDictionaries() }

    @objc private func chooseRoot() {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.directoryURL = store.rootURL
        dialog.prompt = "使用此目录"
        dialog.message = "选择存放 MDX/MDD 词典的目录"
        if dialog.runModal() == .OK, let url = dialog.url {
            store.rootURL = url
            loadDictionaries()
        }
    }
}
