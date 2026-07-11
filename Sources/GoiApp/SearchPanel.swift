import AppKit
import SwiftUI

/// Spotlight-style panel with a standard (system) title bar: the traffic
/// lights live there, and the strip to their right is the system title bar —
/// so dragging and double-click-to-zoom are handled natively by macOS.
/// Non-activating so summoning it doesn't steal focus from the frontmost app.
final class SearchPanel: NSPanel {
    private let model: SearchViewModel

    init(model: SearchViewModel) {
        self.model = model
        let size = Self.defaultContentSize()
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden            // no title text, keep the bar
        title = "Goi"
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        isReleasedWhenClosed = false
        level = .normal
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 820, height: 520)
        setFrameAutosaveName("GoiPanelV3")   // fresh key → new dynamic default applies once
        contentView = NSHostingView(rootView: RootView(model: model))
        delegate = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Comfortable default sized to the screen: wider than the content needs,
    /// but never larger than the usable area (small screens ≈ full screen).
    static func defaultContentSize(for screen: NSScreen? = NSScreen.main) -> NSSize {
        guard let visible = screen?.visibleFrame else { return NSSize(width: 1060, height: 720) }
        let width = min(max(visible.width * 0.72, 960), 1200)
        let height = min(max(visible.height * 0.82, 620), 900)
        return NSSize(width: min(width, visible.width), height: min(height, visible.height))
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show(section: PanelSection) {
        model.section = section
        show()
    }

    func show() {
        // first-ever open: size to the screen and center; afterwards the
        // autosaved frame is restored automatically
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame GoiPanelV3") != nil
        if !hasSavedFrame, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = Self.defaultContentSize(for: screen)
            let origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.minY + visible.height * 0.6 - size.height / 2)
            setFrame(NSRect(origin: origin, size: size), display: false)
        }
        // become a regular app while visible so the window shows up in
        // Cmd-Tab and the Dock; we drop back to accessory when it closes
        NSApp.setActivationPolicy(.regular)
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .goiPanelShown, object: nil)
    }

    /// Hide and return to menu-bar-only (accessory) so no Dock icon lingers.
    func hide() {
        orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // Esc
    override func cancelOperation(_ sender: Any?) {
        hide()
    }
}

extension SearchPanel: NSWindowDelegate {
    // traffic-light close button
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
