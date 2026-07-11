import Foundation
import Compression

enum Zlib {
    /// Decompresses a zlib-wrapped stream (RFC 1950: 2-byte header,
    /// deflate body, adler32 trailer) into exactly `decompressedSize` bytes.
    static func decompress(_ data: Data, decompressedSize: Int) throws -> Data {
        guard data.count > 6 else { throw MdictError.truncated("zlib stream too short") }
        let first = data[data.startIndex]
        let second = data[data.startIndex + 1]
        guard first & 0x0f == 8 else { throw MdictError.corrupted("not a zlib stream (CM=\(first & 0x0f))") }
        guard second & 0x20 == 0 else { throw MdictError.unsupportedFeature("zlib preset dictionary") }

        if decompressedSize == 0 { return Data() }

        // COMPRESSION_ZLIB is raw deflate; skip the 2-byte zlib header.
        let deflate = data.dropFirst(2)
        var dst = Data(count: decompressedSize)
        let written = dst.withUnsafeMutableBytes { (dstRaw: UnsafeMutableRawBufferPointer) -> Int in
            deflate.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dstRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    decompressedSize,
                    srcRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    deflate.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == decompressedSize else {
            throw MdictError.corrupted("zlib: decoded \(written) bytes, expected \(decompressedSize)")
        }
        return dst
    }
}
