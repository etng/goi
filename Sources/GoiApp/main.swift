import AppKit

// headless import mode for testing / scripting: GoiApp --import <path>
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--import"), flag + 1 < arguments.count {
    let path = (arguments[flag + 1] as NSString).expandingTildeInPath
    let store = DictionaryStore()
    let done = DispatchSemaphore(value: 0)
    store.importDictionaries(from: [URL(fileURLWithPath: path)]) { name in
        print("importing \(name)…")
    } completion: { summary in
        print("imported \(summary.imported.count), skipped \(summary.skippedDuplicates.count) duplicates, failed \(summary.failed.count)")
        for failure in summary.failed { print("FAIL \(failure.name): \(failure.reason)") }
        done.signal()
    }
    done.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()

// screenshot mode (for docs): --shot <section> [query] [--dark] [--win <file>]
// shows the panel on the given section (optionally looking a word up) and
// writes the window number to <file> so an external screencapture can grab it.
if let flag = arguments.firstIndex(of: "--shot"), flag + 1 < arguments.count {
    delegate.shotSection = PanelSection(rawValue: arguments[flag + 1])
    // the query, if any, is the single token right after the section name
    // (a leading "--" means there's no query)
    if flag + 2 < arguments.count, !arguments[flag + 2].hasPrefix("--") {
        delegate.shotQuery = arguments[flag + 2]
    }
    delegate.shotDark = arguments.contains("--dark")
    if let w = arguments.firstIndex(of: "--win"), w + 1 < arguments.count {
        delegate.shotWindowFile = arguments[w + 1]
    }
}

app.delegate = delegate
app.run()
