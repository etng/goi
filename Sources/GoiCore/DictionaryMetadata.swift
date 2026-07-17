import Foundation

/// Lightweight, local-first facets for organizing dictionary libraries.
///
/// MDX has no broadly adopted language/publisher schema, and older Goi
/// community records often have an empty `lang`. Keep the inference here so
/// the local library and the downloaded community catalog behave identically
/// without issuing a request for every filter change.
public struct DictionaryMetadata: Equatable, Sendable {
    public enum Language: String, CaseIterable, Codable, Hashable, Sendable {
        case english = "en"
        case japanese = "ja"
        case chinese = "zh"
        case korean = "ko"
        case french = "fr"
        case german = "de"
        case other = "other"

        public var label: String {
            switch self {
            case .english: return "英语"
            case .japanese: return "日语"
            case .chinese: return "汉语"
            case .korean: return "韩语"
            case .french: return "法语"
            case .german: return "德语"
            case .other: return "其他语种"
            }
        }
    }

    public enum Function: String, CaseIterable, Codable, Hashable, Sendable {
        case general
        case bilingual
        case learner
        case pronunciation
        case namesAndPlaces
        case thesaurus

        public var label: String {
            switch self {
            case .general: return "综合词典"
            case .bilingual: return "双语释义"
            case .learner: return "学习词典"
            case .pronunciation: return "发音"
            case .namesAndPlaces: return "人名地名"
            case .thesaurus: return "同义辨析"
            }
        }
    }

    public let languages: [Language]
    public let function: Function
    public let vendor: String

    public init(languages: [Language], function: Function, vendor: String) {
        let unique = Set(languages)
        self.languages = Language.allCases.filter { unique.contains($0) }
        self.function = function
        self.vendor = vendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "其他" : vendor
    }

    public var languageLabel: String {
        languages.map(\.label).joined(separator: " · ")
    }

    /// Compact value accepted by the existing community `lang` field.
    public var languageCode: String {
        languages.map(\.rawValue).joined(separator: "+")
    }

    public static func infer(title: String, summary: String? = nil, declaredLanguage: String? = nil) -> DictionaryMetadata {
        let searchable = normalized([title, summary ?? ""].joined(separator: " "))
        var languages = declaredLanguages(declaredLanguage ?? "")

        let bilingualPairs: [(needles: [String], languages: [Language])] = [
            (["英汉", "英漢", "汉英", "漢英", "英中", "中英", "english chinese"], [.english, .chinese]),
            (["日汉", "日漢", "汉日", "漢日", "日中", "中日", "japanese chinese"], [.japanese, .chinese]),
            (["英日", "日英", "english japanese"], [.english, .japanese]),
            (["韩汉", "韓漢", "汉韩", "漢韓", "韩中", "中韩", "korean chinese"], [.korean, .chinese]),
            (["法汉", "法漢", "汉法", "漢法", "french chinese"], [.french, .chinese]),
            (["德汉", "德漢", "汉德", "漢德", "german chinese"], [.german, .chinese]),
        ]
        for pair in bilingualPairs where containsAny(searchable, pair.needles) {
            languages.formUnion(pair.languages)
        }

        if containsAny(searchable, ["english", "英语", "英語", "英英", "oxford", "webster", "merriam", "collins", "longman", "lla"]) {
            languages.insert(.english)
        }
        if containsAny(searchable, ["japanese", "日本語", "日本人名", "平假名", "日语", "日語", "国語辞典", "國語辭典", "大辞泉", "大辭泉", "大辞林", "大辭林", "明鏡", "新明解", "djs"]) {
            languages.insert(.japanese)
        }
        if containsAny(searchable, ["chinese", "汉语词典", "漢語詞典", "现代汉语", "現代漢語", "中文词典", "中文字典"]) {
            languages.insert(.chinese)
        }
        if containsAny(searchable, ["korean", "韩语", "韓語", "朝鲜语", "朝鮮語"]) { languages.insert(.korean) }
        if containsAny(searchable, ["french", "法语", "法語"]) { languages.insert(.french) }
        if containsAny(searchable, ["german", "德语", "德語"]) { languages.insert(.german) }
        if languages.isEmpty { languages.insert(.other) }

        let function: Function
        switch true {
        case containsAny(searchable, ["アクセント", "发音", "發音", "pronunciation", "音调", "音調"]):
            function = .pronunciation
        case containsAny(searchable, ["人名", "地名", "专名", "專名", "proper name", "place name"]):
            function = .namesAndPlaces
        case containsAny(searchable, ["同义", "同義", "類語", "类语", "thesaurus", "synonym"]):
            function = .thesaurus
        case containsAny(searchable, ["学习", "學習", "learner", "高阶", "高階", "入门", "入門"]):
            function = .learner
        case languages.filter({ $0 != .other }).count > 1:
            function = .bilingual
        default:
            function = .general
        }

        return DictionaryMetadata(
            languages: Language.allCases.filter { languages.contains($0) },
            function: function,
            vendor: inferredVendor(searchable)
        )
    }

    private static func declaredLanguages(_ value: String) -> Set<Language> {
        let tokens = value.lowercased().split { !$0.isLetter }
        var result = Set<Language>()
        for token in tokens {
            let raw = String(token)
            switch raw {
            case "en", "eng", "english": result.insert(.english)
            case "ja", "jp", "jpn", "japanese": result.insert(.japanese)
            case "zh", "zho", "chi", "chinese", "hans", "hant": result.insert(.chinese)
            case "ko", "kor", "korean": result.insert(.korean)
            case "fr", "fra", "fre", "french": result.insert(.french)
            case "de", "deu", "ger", "german": result.insert(.german)
            case "other": result.insert(.other)
            default: break
            }
        }
        return result
    }

    private static func inferredVendor(_ value: String) -> String {
        let vendors: [(needles: [String], label: String)] = [
            (["牛津", "oxford"], "牛津"),
            (["韦氏", "韋氏", "merriam", "webster"], "韦氏"),
            (["柯林斯", "collins"], "柯林斯"),
            (["朗文", "longman", "lla"], "朗文"),
            (["大修館", "大修馆", "明鏡", "明镜"], "大修馆书店"),
            (["三省堂", "大辞林", "大辭林", "新明解"], "三省堂"),
            (["小学館", "小学馆", "大辞泉", "大辭泉", "shogakukan"], "小学馆"),
            (["愛知大学", "爱知大学"], "爱知大学"),
            (["外教社"], "外教社"),
            (["nhk"], "NHK"),
            (["新世纪", "新世紀"], "新世纪"),
        ]
        return vendors.first(where: { containsAny(value, $0.needles) })?.label ?? "其他"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains(normalized($0)) }
    }
}

public struct DictionaryFilter: Equatable, Sendable {
    public var query = ""
    public var language: DictionaryMetadata.Language?
    public var function: DictionaryMetadata.Function?
    public var vendor: String?

    public init() {}

    public var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || language != nil || function != nil || vendor != nil
    }

    public mutating func clear() {
        self = DictionaryFilter()
    }

    public func matches(title: String, originalTitle: String? = nil, metadata: DictionaryMetadata) -> Bool {
        if let language, !metadata.languages.contains(language) { return false }
        if let function, metadata.function != function { return false }
        if let vendor, metadata.vendor != vendor { return false }

        let needle = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        let haystack = Self.normalized([
            title,
            originalTitle ?? "",
            metadata.languageLabel,
            metadata.function.label,
            metadata.vendor,
        ].joined(separator: " "))
        return haystack.contains(needle)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}
