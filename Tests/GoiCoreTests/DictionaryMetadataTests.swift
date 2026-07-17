import XCTest
@testable import GoiCore

final class DictionaryMetadataTests: XCTestCase {
    func testInfersFacetsFromCurrentDictionaryNames() {
        assertMetadata(
            "牛津高阶英汉双解词典（第9版）",
            languages: [.english, .chinese], function: .learner, vendor: "牛津"
        )
        assertMetadata(
            "（大修館）明鏡国語辞典［第三版］",
            languages: [.japanese], function: .general, vendor: "大修馆书店"
        )
        assertMetadata(
            "NHK日本語発音アクセント辞書",
            languages: [.japanese], function: .pronunciation, vendor: "NHK"
        )
        assertMetadata(
            "日本人名地名平假名漢字雙向詞典 v0.2版",
            languages: [.japanese], function: .namesAndPlaces, vendor: "其他"
        )
        assertMetadata(
            "外教社·柯林斯汉英大词典",
            languages: [.english, .chinese], function: .bilingual, vendor: "柯林斯"
        )
    }

    func testDeclaredLanguageComplementsTitleInference() {
        let metadata = DictionaryMetadata.infer(title: "专业术语资料库", declaredLanguage: "de+zh-Hans")
        XCTAssertEqual(metadata.languages, [.chinese, .german])
        XCTAssertEqual(metadata.function, .bilingual)
        XCTAssertEqual(metadata.languageCode, "zh+de")
    }

    func testUnknownDictionaryRemainsFilterable() {
        let metadata = DictionaryMetadata.infer(title: "Untitled Archive")
        XCTAssertEqual(metadata.languages, [.other])
        XCTAssertEqual(metadata.function, .general)
        XCTAssertEqual(metadata.vendor, "其他")
    }

    private func assertMetadata(
        _ title: String,
        languages: [DictionaryMetadata.Language],
        function: DictionaryMetadata.Function,
        vendor: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let metadata = DictionaryMetadata.infer(title: title)
        XCTAssertEqual(metadata.languages, languages, file: file, line: line)
        XCTAssertEqual(metadata.function, function, file: file, line: line)
        XCTAssertEqual(metadata.vendor, vendor, file: file, line: line)
    }
}
