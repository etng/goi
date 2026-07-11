import Foundation
import NaturalLanguage

enum Lemma {
    /// Base-form candidates for a word that failed exact lookup, best first.
    /// English via NLTagger + rules; Japanese via mecab when installed.
    static func candidates(for word: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.lowercased() != word.lowercased(), !out.contains(t) { out.append(t) }
        }

        if word.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
            for candidate in Mecab.baseForms(of: word) { add(candidate) }
        }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        tagger.enumerateTags(
            in: word.startIndex..<word.endIndex, unit: .word, scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if let lemma = tag?.rawValue { add(lemma) }
            return false
        }

        // rule fallbacks for words NLTagger doesn't know
        let lower = word.lowercased()
        if lower.hasSuffix("ies"), lower.count > 4 { add(String(lower.dropLast(3)) + "y") }
        if lower.hasSuffix("es"), lower.count > 3 { add(String(lower.dropLast(2))) }
        if lower.hasSuffix("s"), lower.count > 3 { add(String(lower.dropLast())) }
        if lower.hasSuffix("ied"), lower.count > 4 { add(String(lower.dropLast(3)) + "y") }
        if lower.hasSuffix("ed"), lower.count > 4 {
            add(String(lower.dropLast(2)))
            add(String(lower.dropLast(1))) // hoped -> hope
        }
        if lower.hasSuffix("ing"), lower.count > 5 {
            add(String(lower.dropLast(3)))
            add(String(lower.dropLast(3)) + "e") // making -> make
        }
        return out
    }
}
