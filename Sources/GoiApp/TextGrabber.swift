import AppKit
import ApplicationServices

/// Grabs the currently selected text from the frontmost app for "select &
/// look up". Accessibility first (no clipboard disruption); falls back to
/// synthesizing ⌘C and reading the pasteboard.
enum TextGrabber {
    struct Grab {
        let text: String
        /// The sentence the selection sits in, when we can recover it — used
        /// as an example sentence in the wordbook / Anki cards.
        let context: String?
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for accessibility access (opens the system dialog once).
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func grab() -> Grab? {
        if let viaAX = grabViaAccessibility() { return viaAX }
        return grabViaClipboard()
    }

    // MARK: - Accessibility

    private static func grabViaAccessibility() -> Grab? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let axElement = element as! AXUIElement

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return Grab(text: trimmed, context: contextSentence(around: axElement, selection: text))
    }

    /// Best-effort: read the element's whole value and the selection range,
    /// then slice out the enclosing sentence.
    private static func contextSentence(around element: AXUIElement, selection: String) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let full = valueRef as? String, full.count > selection.count else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location != kCFNotFound else { return nil }

        let ns = full as NSString
        let loc = max(0, min(range.location, ns.length))
        // expand to sentence terminators on both sides
        let terminators = CharacterSet(charactersIn: "。！？.!?\n")
        var start = loc
        while start > 0 {
            let c = ns.substring(with: NSRange(location: start - 1, length: 1))
            if c.rangeOfCharacter(from: terminators) != nil { break }
            start -= 1
        }
        var end = min(loc + range.length, ns.length)
        while end < ns.length {
            let c = ns.substring(with: NSRange(location: end, length: 1))
            end += 1
            if c.rangeOfCharacter(from: terminators) != nil { break }
        }
        let sentence = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty || sentence == selection ? nil : sentence
    }

    // MARK: - Clipboard fallback

    private static func grabViaClipboard() -> Grab? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        }
        let previousChangeCount = pasteboard.changeCount

        synthesizeCopy()

        // give the frontmost app a beat to put text on the pasteboard
        var text: String?
        for _ in 0..<20 {
            if pasteboard.changeCount != previousChangeCount {
                text = pasteboard.string(forType: .string)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        // restore the user's clipboard
        pasteboard.clearContents()
        if let saved {
            for (type, data) in saved { pasteboard.setData(data, forType: type) }
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : Grab(text: trimmed, context: nil)
    }

    private static func synthesizeCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdC = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'c'
        cmdC?.flags = .maskCommand
        let cmdCUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        cmdCUp?.flags = .maskCommand
        cmdC?.post(tap: .cghidEventTap)
        cmdCUp?.post(tap: .cghidEventTap)
    }
}
