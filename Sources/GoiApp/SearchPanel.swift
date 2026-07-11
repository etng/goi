import AppKit
import SwiftUI

/// Spotlight-style floating panel. Non-activating so it can take keystrokes
/// without stealing focus from the frontmost app.
final class SearchPanel: NSPanel {
    private let model: SearchViewModel

    init(model: SearchViewModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        // window dragging happens via the header bar only — background drags
        // would swallow the tab strip's drag-to-reorder
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // normal level so switching to another app sends it behind as usual
        // (⌥Space re-summons); floating would pin it permanently on top
        level = .normal
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 860, height: 540)
        // V2 autosave key so the previous (smaller) saved size is dropped and
        // everyone gets the wider default once
        setFrameAutosaveName("GoiPanelV2")
        contentView = NSHostingView(rootView: RootView(model: model))
    }

    override var canBecomeKey: Bool { true }

    private var preZoomFrame: NSRect?

    /// Manual maximize/restore. NSPanel's built-in zoom is unreliable with a
    /// hidden titlebar, so we toggle against the screen's visible frame.
    func toggleZoom() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        if frame == visible {
            setFrame(preZoomFrame ?? NSRect(x: visible.midX - 530, y: visible.midY - 360, width: 1060, height: 720),
                     display: true, animate: true)
            preZoomFrame = nil
        } else {
            preZoomFrame = frame
            setFrame(visible, display: true, animate: true)
        }
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            show()
        }
    }

    func show(section: PanelSection) {
        model.section = section
        show()
    }

    func show() {
        // respect the user's remembered frame; center only on first-ever open
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame GoiPanelV2") != nil
        if !hasSavedFrame, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - self.frame.width / 2
            let y = frame.minY + frame.height * 0.62 - self.frame.height / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .goiPanelShown, object: nil)
    }

    // Esc
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
