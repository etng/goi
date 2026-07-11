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
    private var selectionHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppTheme.applySaved()
        installMainMenu()

        vocab = VocabStore(url: DictionaryStore.supportDirectory.appendingPathComponent("vocab.sqlite3"))
        model = SearchViewModel(store: store, vocab: vocab)
        panel = SearchPanel(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
        if let button = statusItem.button {
            button.title = isDev ? "語ᴅ" : "語"
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Goi — ⌥Space 查词 · ⌘⌥Space 划词"
        }

        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            self?.panel.toggle()
        }
        // ⌘⌥Space: look up the text selected in whatever app is frontmost
        selectionHotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in
            self?.lookUpSelection()
        }

        NotificationCenter.default.addObserver(
            forName: .goiReloadRequested, object: nil, queue: .main
        ) { [weak self] _ in
            self?.loadDictionaries()
        }

        loadDictionaries()

        Updater.checkOnLaunchIfDue { [weak self] release in
            self?.presentUpdate(release)
        }
    }

    private func presentUpdate(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 Goi \(release.version)"
        alert.informativeText = (release.notes.isEmpty ? "" : release.notes + "\n\n")
            + "当前版本 \(Updater.currentVersion)。"
        alert.addButton(withTitle: release.downloadURL != nil ? "下载" : "查看发布")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: release.downloadURL ?? release.htmlURL)!)
        }
    }

    /// Accessory apps have no visible menu bar, but cmd-V/C/X/A only work
    /// when a main menu supplies the key equivalents — without this the
    /// search field can't paste.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Goi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
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
        menu.addItem(withTitle: "划词查询选中文本  ⌘⌥Space", action: #selector(triggerSelectionLookup), keyEquivalent: "").target = self
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

    private func lookUpSelection() {
        guard TextGrabber.isTrusted else {
            promptForAccessibility()
            return
        }
        // AX/clipboard reads must be off the hotkey callback's context
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let grab = TextGrabber.grab()
            DispatchQueue.main.async {
                guard let self else { return }
                guard let grab else {
                    self.panel.show()
                    return
                }
                self.panel.show(section: .search)
                self.model.lookupSelection(grab.text, context: grab.context)
            }
        }
    }

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "划词取词需要「辅助功能」权限"
        alert.informativeText = "Goi 要读取其他应用里选中的文字。请在「系统设置 → 隐私与安全性 → 辅助功能」中打开 Goi 的开关，然后再次按 ⌘⌥Space。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            TextGrabber.requestTrust()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc private func showPanel() { panel.show() }

    @objc private func triggerSelectionLookup() { lookUpSelection() }

    @objc private func openReport() { NSWorkspace.shared.open(DictionaryStore.reportURL) }

    @objc private func reload() { loadDictionaries() }
}
