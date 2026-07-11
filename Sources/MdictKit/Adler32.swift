import Foundation

enum Adler32 {
    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var counter = 0
        for byte in bytes {
            a &+= UInt32(byte)
            b &+= a
            counter += 1
            // keep sums below overflow; 5552 is zlib's NMAX
            if counter == 5552 {
                a %= 65521
                b %= 65521
                counter = 0
            }
        }
        a %= 65521
        b %= 65521
        return b << 16 | a
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            checksum(raw.bindMemory(to: UInt8.self))
        }
    }
}
