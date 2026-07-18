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

        for pair in bilingualPairs where containsAny(searchable, pair.needles) {
            languages.formUnion(pair.languages)
        }

        if containsAny(searchable, englishNeedles) {
            languages.insert(.english)
        }
        if containsAny(searchable, japaneseNeedles) {
            languages.insert(.japanese)
        }
        if containsAny(searchable, chineseNeedles) {
            languages.insert(.chinese)
        }
        if containsAny(searchable, koreanNeedles) { languages.insert(.korean) }
        if containsAny(searchable, frenchNeedles) { languages.insert(.french) }
        if containsAny(searchable, germanNeedles) { languages.insert(.german) }
        if languages.isEmpty { languages.insert(.other) }

        let function: Function
        switch true {
        case containsAny(searchable, pronunciationNeedles):
            function = .pronunciation
        case containsAny(searchable, namesAndPlacesNeedles):
            function = .namesAndPlaces
        case containsAny(searchable, thesaurusNeedles):
            function = .thesaurus
        case containsAny(searchable, learnerNeedles):
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
        vendorRules.first(where: { containsAny(value, $0.needles) })?.label ?? "其他"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private static func normalizedNeedles(_ values: [String]) -> [String] {
        values.map(normalized)
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static let bilingualPairs: [(needles: [String], languages: [Language])] = [
        (normalizedNeedles(["英汉", "英漢", "汉英", "漢英", "英中", "中英", "english chinese"]), [.english, .chinese]),
        (normalizedNeedles(["日汉", "日漢", "汉日", "漢日", "日中", "中日", "japanese chinese"]), [.japanese, .chinese]),
        (normalizedNeedles(["英日", "日英", "english japanese"]), [.english, .japanese]),
        (normalizedNeedles(["韩汉", "韓漢", "汉韩", "漢韓", "韩中", "中韩", "korean chinese"]), [.korean, .chinese]),
        (normalizedNeedles(["法汉", "法漢", "汉法", "漢法", "french chinese"]), [.french, .chinese]),
        (normalizedNeedles(["德汉", "德漢", "汉德", "漢德", "german chinese"]), [.german, .chinese]),
    ]
    private static let englishNeedles = normalizedNeedles(["english", "英语", "英語", "英英", "oxford", "webster", "merriam", "collins", "longman", "lla"])
    private static let japaneseNeedles = normalizedNeedles(["japanese", "日本語", "日本人名", "平假名", "日语", "日語", "国語辞典", "國語辭典", "大辞泉", "大辭泉", "大辞林", "大辭林", "明鏡", "新明解", "djs"])
    private static let chineseNeedles = normalizedNeedles(["chinese", "汉语词典", "漢語詞典", "现代汉语", "現代漢語", "中文词典", "中文字典"])
    private static let koreanNeedles = normalizedNeedles(["korean", "韩语", "韓語", "朝鲜语", "朝鮮語"])
    private static let frenchNeedles = normalizedNeedles(["french", "法语", "法語"])
    private static let germanNeedles = normalizedNeedles(["german", "德语", "德語"])
    private static let pronunciationNeedles = normalizedNeedles(["アクセント", "发音", "發音", "pronunciation", "音调", "音調"])
    private static let namesAndPlacesNeedles = normalizedNeedles(["人名", "地名", "专名", "專名", "proper name", "place name"])
    private static let thesaurusNeedles = normalizedNeedles(["同义", "同義", "類語", "类语", "thesaurus", "synonym"])
    private static let learnerNeedles = normalizedNeedles(["学习", "學習", "learner", "高阶", "高階", "入门", "入門"])
    private static let vendorRules: [(needles: [String], label: String)] = [
        (normalizedNeedles(["牛津", "oxford"]), "牛津"),
        (normalizedNeedles(["韦氏", "韋氏", "merriam", "webster"]), "韦氏"),
        (normalizedNeedles(["柯林斯", "collins"]), "柯林斯"),
        (normalizedNeedles(["朗文", "longman", "lla"]), "朗文"),
        (normalizedNeedles(["大修館", "大修馆", "明鏡", "明镜"]), "大修馆书店"),
        (normalizedNeedles(["三省堂", "大辞林", "大辭林", "新明解"]), "三省堂"),
        (normalizedNeedles(["小学館", "小学馆", "大辞泉", "大辭泉", "shogakukan"]), "小学馆"),
        (normalizedNeedles(["愛知大学", "爱知大学"]), "爱知大学"),
        (normalizedNeedles(["外教社"]), "外教社"),
        (normalizedNeedles(["nhk"]), "NHK"),
        (normalizedNeedles(["新世纪", "新世紀"]), "新世纪"),
    ]
}

/// Prepared text and facets for one dictionary. Build this only when a catalog
/// changes; filter interactions then compare against the stored normalized text.
public struct DictionaryCatalogIndexEntry: Equatable, Sendable {
    public let metadata: DictionaryMetadata
    fileprivate let normalizedSearchText: String

    public init(title: String, originalTitle: String? = nil, metadata: DictionaryMetadata) {
        self.metadata = metadata
        normalizedSearchText = Self.normalized([
            title,
            originalTitle ?? "",
            metadata.languageLabel,
            metadata.function.label,
            metadata.vendor,
        ].joined(separator: " "))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }
}

/// One prepared predicate per filter change. It normalizes the user's query
/// once, rather than once per dictionary and once per SwiftUI body access.
public struct DictionaryFilterMatcher: Equatable, Sendable {
    private let language: DictionaryMetadata.Language?
    private let function: DictionaryMetadata.Function?
    private let vendor: String?
    private let normalizedQuery: String

    fileprivate init(filter: DictionaryFilter) {
        language = filter.language
        function = filter.function
        vendor = filter.vendor
        normalizedQuery = filter.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    public func matches(_ entry: DictionaryCatalogIndexEntry) -> Bool {
        if let language, !entry.metadata.languages.contains(language) { return false }
        if let function, entry.metadata.function != function { return false }
        if let vendor, entry.metadata.vendor != vendor { return false }
        return normalizedQuery.isEmpty || entry.normalizedSearchText.contains(normalizedQuery)
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

    public func preparedMatcher() -> DictionaryFilterMatcher {
        DictionaryFilterMatcher(filter: self)
    }

    public func matches(title: String, originalTitle: String? = nil, metadata: DictionaryMetadata) -> Bool {
        preparedMatcher().matches(DictionaryCatalogIndexEntry(
            title: title,
            originalTitle: originalTitle,
            metadata: metadata
        ))
    }
}
