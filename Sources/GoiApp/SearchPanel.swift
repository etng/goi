import AppKit
import SwiftUI

/// Spotlight-style floating panel. Non-activating so it can take keystrokes
/// without stealing focus from the frontmost app.
final class SearchPanel: NSPanel {
    init(model: SearchViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: SearchView(model: model))
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if let screen = NSScreen.main {
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
