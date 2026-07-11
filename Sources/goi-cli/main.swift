import Foundation
import MdictKit

let usage = """
goi-cli — MdictKit command-line prototype

USAGE:
  goi-cli info <file.mdx|mdd>              Show header and section stats
  goi-cli keys <file> [--limit N]          Dump keys (default 20, 0 = all)
  goi-cli lookup <file.mdx> <word>         Print matching record(s) as text
  goi-cli extract <file.mdd> <key> [-o F]  Write a resource to a file/stdout
  goi-cli scan <directory>                 Parse every .mdx/.mdd found and
                                           verify a sample record from each
"""

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func humanBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var value = Double(n)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: unit == 0 ? "%.0f%@" : "%.1f%@", value, units[unit])
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die(usage) }

switch command {
case "info":
    guard args.count >= 2 else { die(usage) }
    let file = try MdictFile(url: URL(fileURLWithPath: args[1]))
    let h = file.header
    print("file:      \(args[1])")
    print("kind:      \(file.isResource ? "MDD resource archive" : "MDX dictionary")")
    print("title:     \(h.title ?? "-")")
    print("version:   \(h.version)")
    print("encoding:  \(h.codec.name)")
    print("encrypted: \(h.encrypted)")
    print("entries:   \(file.entryCount)")
    if let first = file.keys.first, let last = file.keys.last {
        print("first key: \(first.key)")
        print("last key:  \(last.key)")
    }

case "keys":
    guard args.count >= 2 else { die(usage) }
    let file = try MdictFile(url: URL(fileURLWithPath: args[1]))
    var limit = 20
    if let i = args.firstIndex(of: "--limit"), i + 1 < args.count { limit = Int(args[i + 1]) ?? 20 }
    let slice = limit == 0 ? file.keys[...] : file.keys.prefix(limit)
    for entry in slice { print(entry.key) }

case "lookup":
    guard args.count >= 3 else { die(usage) }
    let file = try MdictFile(url: URL(fileURLWithPath: args[1]))
    let word = args[2]
    let hits = file.lookup(word)
    guard !hits.isEmpty else { die("not found: \(word)") }
    for index in hits {
        print("=== \(file.keys[index].key) ===")
        print(try file.text(at: index))
    }

case "extract":
    guard args.count >= 3 else { die(usage) }
    let file = try MdictFile(url: URL(fileURLWithPath: args[1]))
    let key = args[2]
    let hits = file.lookup(key)
    guard let index = hits.first else { die("not found: \(key)") }
    let content = try file.record(at: index)
    if let o = args.firstIndex(of: "-o"), o + 1 < args.count {
        try content.write(to: URL(fileURLWithPath: args[o + 1]))
        print("wrote \(humanBytes(content.count)) to \(args[o + 1])")
    } else {
        FileHandle.standardOutput.write(content)
    }

case "scan":
    guard args.count >= 2 else { die(usage) }
    let root = URL(fileURLWithPath: args[1])
    var targets: [URL] = []
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    while let item = enumerator?.nextObject() as? URL {
        guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        if ["mdx", "mdd"].contains(item.pathExtension.lowercased()) {
            targets.append(item)
        }
    }
    targets.sort { $0.path < $1.path }
    print("scanning \(targets.count) files under \(root.path)\n")

    var failures: [(String, String)] = []
    let started = Date()
    for target in targets {
        let name = target.path.replacingOccurrences(of: root.path + "/", with: "")
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        autoreleasepool {
            do {
                let opened = Date()
                let file = try MdictFile(url: target)
                // verify a record from the middle of the file actually decodes
                let sampleIndex = file.entryCount / 2
                var sampleNote = "empty"
                if file.entryCount > 0 {
                    let key = file.keys[sampleIndex].key
                    if file.isResource {
                        let content = try file.record(at: sampleIndex)
                        sampleNote = "'\(key)' \(humanBytes(content.count))"
                    } else {
                        let text = try file.text(at: sampleIndex)
                        sampleNote = "'\(key)' \(text.count) chars"
                    }
                }
                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(opened))
                print("OK   v\(file.header.version) \(file.header.codec.name)\tenc=\(file.header.encrypted) \(file.entryCount) keys\t\(humanBytes(size))\t\(elapsed)\t\(name)\tsample: \(sampleNote)")
            } catch {
                print("FAIL \(name): \(error)")
                failures.append((name, "\(error)"))
            }
        }
    }
    let total = String(format: "%.1fs", Date().timeIntervalSince(started))
    print("\n\(targets.count - failures.count)/\(targets.count) parsed in \(total)")
    if !failures.isEmpty {
        print("\nfailures:")
        for (name, error) in failures { print("  \(name): \(error)") }
        exit(2)
    }

default:
    die(usage)
}
