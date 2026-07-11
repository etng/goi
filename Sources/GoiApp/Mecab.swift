import Foundation

/// Japanese deconjugation via the mecab CLI (M4). Optional dependency:
/// detected at runtime, so `brew install mecab mecab-ipadic` is all it
/// takes to light this up. Absent mecab, Japanese lemma fallback is
/// simply unavailable (reported in the dictionary report).
enum Mecab {
    static let path: String? = ["/opt/homebrew/bin/mecab", "/usr/local/bin/mecab", "/usr/bin/mecab"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isAvailable: Bool { path != nil }

    /// Dictionary base forms for an inflected word/phrase, best first.
    /// IPADIC feature CSV: pos,pos2,pos3,pos4,conj_type,conj_form,base,reading,pron
    static func baseForms(of word: String) -> [String] {
        guard let path else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        stdin.fileHandleForWriting.write(Data((word + "\n").utf8))
        stdin.fileHandleForWriting.closeFile()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: output, encoding: .utf8) else { return [] }

        var tokens: [(surface: String, base: String)] = []
        for line in text.split(separator: "\n") {
            if line == "EOS" { break }
            let cols = line.split(separator: "\t", maxSplits: 1)
            guard cols.count == 2 else { continue }
            let features = cols[1].split(separator: ",", omittingEmptySubsequences: false)
            let base = features.count > 6 ? String(features[6]) : "*"
            tokens.append((String(cols[0]), base == "*" ? String(cols[0]) : base))
        }
        guard !tokens.isEmpty else { return [] }

        var candidates: [String] = []
        // 食べました -> tokens [食べ->食べる][まし][た]: the first token's base form
        if tokens[0].base != tokens[0].surface { candidates.append(tokens[0].base) }
        // longest prefix of surfaces + base form of the token that ends it,
        // e.g. 読み込んだ -> 読み込む (読み込ん + だ)
        if tokens.count > 1 {
            for end in stride(from: tokens.count - 1, through: 1, by: -1) {
                let prefix = tokens[..<end].dropLast().map(\.surface).joined()
                let candidate = prefix + tokens[end - 1].base
                if candidate != word, !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }
}
