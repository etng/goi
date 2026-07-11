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
    private var wordbookWindow: NSWindow?
    private var settingsWindow: NSWindow?

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
        menu.addItem(withTitle: "生词本…", action: #selector(openWordbook), keyEquivalent: "").target = self
        menu.addItem(withTitle: "词典顺序…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "打开解析报告", action: #selector(openReport), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "更换词典目录…", action: #selector(chooseRoot), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重新加载词典", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Goi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openWordbook() {
        NSApp.activate(ignoringOtherApps: true)
        if wordbookWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Goi 生词本"
            window.isReleasedWhenClosed = false
            window.center()
            wordbookWindow = window
        }
        // fresh content each open so the list reflects the latest lookups
        wordbookWindow?.contentView = NSHostingView(rootView: WordbookView(vocab: vocab, store: store))
        wordbookWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Goi 设置"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(
            rootView: SettingsView(store: store) { [weak self] in self?.model.orderChanged() }
        )
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

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
