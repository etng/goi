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

    func testFilterCombinesFacetsAndSearchLocally() {
        let metadata = DictionaryMetadata.infer(title: "牛津高阶英汉双解词典（第9版）")
        var filter = DictionaryFilter()
        filter.language = .english
        filter.function = .learner
        filter.vendor = "牛津"
        filter.query = "第9版"
        XCTAssertTrue(filter.matches(title: "牛津高阶英汉双解词典（第9版）", metadata: metadata))

        filter.language = .japanese
        XCTAssertFalse(filter.matches(title: "牛津高阶英汉双解词典（第9版）", metadata: metadata))
        filter.clear()
        XCTAssertFalse(filter.isActive)
    }

    func testCurrentCommunityCatalogHasUsefulLanguageFacets() {
        let titles = [
            "（大修館）明鏡国語辞典［第三版］", "爱知大学中日辞典", "大辞泉",
            "三省堂スーパー大辞林3.0", "例解学習国語辞典［第十一版］", "牛津高阶英汉双解词典（第9版）",
            "日本人名地名平假名漢字雙向詞典 v0.2版", "日汉词典", "外教社·柯林斯汉英大词典",
            "韦氏高阶英汉双解词典2019", "小学馆日中词典", "新明解第5版", "新日漢大辭典",
            "新世纪英汉大词典", "英汉大词典（第2版）", "简明英汉字典增强版 - CSS", "DJS", "LLA",
            "NHK日本語発音アクセント辞書", "三省堂国語辞典　第八版", "小学館日中辞典v3", "新世纪日汉双解大辞典",
        ]
        let metadata = titles.map { DictionaryMetadata.infer(title: $0) }
        XCTAssertEqual(metadata.filter { $0.languages == [.english, .chinese] }.count, 6)
        XCTAssertEqual(metadata.filter { $0.languages == [.japanese, .chinese] }.count, 6)
        XCTAssertEqual(metadata.filter { $0.languages == [.english] }.count, 1)
        XCTAssertEqual(metadata.filter { $0.languages == [.japanese] }.count, 9)
        XCTAssertFalse(metadata.contains { $0.languages == [.other] })
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
