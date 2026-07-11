import Foundation

/// Sequential big-endian reader over a (possibly memory-mapped) Data.
/// Offsets are relative to the start of `data` regardless of its startIndex.
struct DataReader {
    let data: Data
    private let base: Int
    var pos: Int = 0

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.base = data.startIndex
        self.pos = offset
    }

    var count: Int { data.count }
    var remaining: Int { data.count - pos }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else {
            throw MdictError.truncated("need \(n) bytes at offset \(pos), have \(remaining)")
        }
        let d = data.subdata(in: (base + pos)..<(base + pos + n))
        pos += n
        return d
    }

    mutating func byteArray(_ n: Int) throws -> [UInt8] { [UInt8](try bytes(n)) }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, remaining >= n else {
            throw MdictError.truncated("skip \(n) at offset \(pos), have \(remaining)")
        }
        pos += n
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }

    mutating func u16be() throws -> UInt16 {
        let b = try byteArray(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func u32be() throws -> UInt32 {
        let b = try byteArray(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func u32le() throws -> UInt32 {
        let b = try byteArray(4)
        return UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
    }

    mutating func u64be() throws -> UInt64 {
        let hi = try u32be()
        let lo = try u32be()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    /// Reads a big-endian unsigned int of 4 or 8 bytes (MDX v1 vs v2 number width).
    mutating func number(width: Int) throws -> UInt64 {
        width == 8 ? try u64be() : UInt64(try u32be())
    }
}
