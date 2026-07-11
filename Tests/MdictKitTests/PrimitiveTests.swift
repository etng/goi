import XCTest
@testable import MdictKit

final class PrimitiveTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testRIPEMD128Vectors() {
        XCTAssertEqual(hex(RIPEMD128.hash([])), "cdf26213a150dc3ecb610f18f6b38b46")
        XCTAssertEqual(hex(RIPEMD128.hash(Array("abc".utf8))), "c14a12199c66e4ba84636b0f69144c77")
        XCTAssertEqual(hex(RIPEMD128.hash(Array("message digest".utf8))), "9e327b3d6e523062afc1132d7df9d1b8")
        XCTAssertEqual(
            hex(RIPEMD128.hash(Array("abcdefghijklmnopqrstuvwxyz".utf8))),
            "fd2aa607f71dc8f510714922b371834e"
        )
    }

    func testAdler32() {
        // zlib.adler32(b"Wikipedia") == 0x11E60398
        XCTAssertEqual(Adler32.checksum(Data("Wikipedia".utf8)), 0x11E6_0398)
        XCTAssertEqual(Adler32.checksum(Data()), 1)
    }

    func testLZOLiteralsOnly() throws {
        // prologue literal run of 2 ("hi") followed by the end marker
        let compressed = Data([19, 0x68, 0x69, 0x11, 0x00, 0x00])
        let out = try LZO.decompress(compressed, decompressedSize: 2)
        XCTAssertEqual(String(data: out, encoding: .utf8), "hi")
    }

    func testLZOOverlappingMatch() throws {
        // "a" + M3 match (distance 1, length 5) -> "aaaaaa", then end marker
        let compressed = Data([18, 0x61, 35, 0, 0, 0x11, 0x00, 0x00])
        let out = try LZO.decompress(compressed, decompressedSize: 6)
        XCTAssertEqual(String(data: out, encoding: .utf8), "aaaaaa")
    }

    func testLZORejectsBadSize() {
        let compressed = Data([19, 0x68, 0x69, 0x11, 0x00, 0x00])
        XCTAssertThrowsError(try LZO.decompress(compressed, decompressedSize: 5))
    }

    func testZlibRoundTrip() throws {
        // zlib.compress(b"hello world") from CPython
        let compressed = Data([
            0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
            0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x1a,
            0x0b, 0x04, 0x5d,
        ])
        let out = try Zlib.decompress(compressed, decompressedSize: 11)
        XCTAssertEqual(String(data: out, encoding: .utf8), "hello world")
    }
}
