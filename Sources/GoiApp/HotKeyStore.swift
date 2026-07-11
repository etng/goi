import AppKit
import Carbon.HIToolbox

/// A user-configurable global shortcut: a key code plus Carbon modifier mask,
/// with a human-readable label for display.
struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey / optionKey / controlKey / shiftKey
    var label: String

    static let panelDefault = HotKeyConfig(
        keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥Space"
    )
    // NOT ⌘⌥Space — that's macOS's "show Finder search window". ⌃⌥Space is free.
    static let selectionDefault = HotKeyConfig(
        keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space"
    )
}

/// Persists the two shortcuts and converts recorded key events into configs.
enum HotKeyStore {
    static var panel: HotKeyConfig {
        get { load("hotkeyPanel") ?? .panelDefault }
        set { save(newValue, "hotkeyPanel") }
    }
    static var selection: HotKeyConfig {
        get { load("hotkeySelection") ?? .selectionDefault }
        set { save(newValue, "hotkeySelection") }
    }

    private static func load(_ key: String) -> HotKeyConfig? {
        let d = UserDefaults.standard
        guard d.object(forKey: "\(key).code") != nil else { return nil }
        return HotKeyConfig(
            keyCode: UInt32(d.integer(forKey: "\(key).code")),
            modifiers: UInt32(d.integer(forKey: "\(key).mods")),
            label: d.string(forKey: "\(key).label") ?? "?"
        )
    }
    private static func save(_ c: HotKeyConfig, _ key: String) {
        let d = UserDefaults.standard
        d.set(Int(c.keyCode), forKey: "\(key).code")
        d.set(Int(c.modifiers), forKey: "\(key).mods")
        d.set(c.label, forKey: "\(key).label")
    }

    /// Builds a config from a recorded key-down event, or nil if the event has
    /// no modifier (a bare key would be a terrible global shortcut).
    static func config(from event: NSEvent) -> HotKeyConfig? {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        guard carbon != 0 else { return nil }
        return HotKeyConfig(keyCode: UInt32(event.keyCode), modifiers: carbon,
                            label: symbols + keyName(event))
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        default:
            let s = (event.charactersIgnoringModifiers ?? "").uppercased()
            return s.isEmpty ? "键\(event.keyCode)" : s
        }
    }
}
