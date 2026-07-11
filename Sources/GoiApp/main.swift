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
app.delegate = delegate
app.run()
