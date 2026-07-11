import AppKit

/// App-wide light/dark override. Setting NSApp.appearance cascades to SwiftUI
/// views and to WKWebView's effective appearance, which flips the entries'
/// `prefers-color-scheme` dark CSS. One control, everything follows.
enum AppTheme: String {
    case system, light, dark

    private static let key = "appearance"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    static func apply(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: key)
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Call at launch to restore the saved choice.
    static func applySaved() { apply(current) }
}
