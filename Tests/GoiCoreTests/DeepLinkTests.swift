import Foundation
import XCTest
@testable import GoiCore

final class DeepLinkTests: XCTestCase {
    func testParsesProductionAndDevelopmentSearchLinks() {
        XCTAssertEqual(
            parse("goi://search?word=justforfun"),
            .search(word: "justforfun")
        )
        XCTAssertEqual(
            parse("goi-dev://search/?word=%E5%AD%A6%E4%B9%A0", scheme: "goi-dev"),
            .search(word: "学习")
        )
        XCTAssertEqual(
            parse("goi://search?word=two%20words"),
            .search(word: "two words")
        )
    }

    func testRejectsOtherRoutesAndSchemes() {
        XCTAssertNil(parse("other://search?word=test"))
        XCTAssertNil(parse("goi://d/entry/123?word=test"))
        XCTAssertNil(parse("goi://history?word=test"))
    }

    func testRejectsAmbiguousOrUnexpectedParameters() {
        XCTAssertNil(parse("goi://search"))
        XCTAssertNil(parse("goi://search?word="))
        XCTAssertNil(parse("goi://search?word=one&word=two"))
        XCTAssertNil(parse("goi://search?word=test&source=browser"))
        XCTAssertNil(parse("goi://user@search?word=test"))
        XCTAssertNil(parse("goi://search?word=test#fragment"))
    }

    func testRejectsControlCharactersAndOversizedSearches() {
        XCTAssertNil(parse("goi://search?word=line%0Abreak"))
        let oversized = String(repeating: "a", count: GoiDeepLink.maximumSearchLength + 1)
        var components = URLComponents()
        components.scheme = "goi"
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "word", value: oversized)]
        XCTAssertNil(components.url.flatMap { GoiDeepLink.parse($0, expectedScheme: "goi") })
    }

    private func parse(_ raw: String, scheme: String = "goi") -> GoiDeepLink? {
        URL(string: raw).flatMap { GoiDeepLink.parse($0, expectedScheme: scheme) }
    }
}
