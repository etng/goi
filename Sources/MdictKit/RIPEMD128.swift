import Foundation

/// RIPEMD-128, needed only to derive the decryption key of MDX files with
/// an encrypted key index (Encrypted & 2).
enum RIPEMD128 {
    // message word selection, left/right lines, 4 rounds x 16 steps
    private static let rL: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
    ]
    private static let rR: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
    ]
    private static let sL: [Int] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
    ]
    private static let sR: [Int] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
    ]
    private static let kL: [UInt32] = [0x0000_0000, 0x5a82_7999, 0x6ed9_eba1, 0x8f1b_bcdc]
    private static let kR: [UInt32] = [0x50a2_8be6, 0x5c4d_d124, 0x6d70_3ef3, 0x0000_0000]

    @inline(__always) private static func rol(_ x: UInt32, _ n: Int) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    // f1..f4 applied to left line in order and to right line in reverse order
    @inline(__always) private static func f(_ round: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch round {
        case 0: return x ^ y ^ z
        case 1: return (x & y) | (~x & z)
        case 2: return (x | ~y) ^ z
        default: return (x & z) | (y & ~z)
        }
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        // MD4-style padding: 0x80, zeros, 64-bit little-endian bit length
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((bitLen >> (8 * UInt64(i))) & 0xff)) }

        var h: [UInt32] = [0x6745_2301, 0xefcd_ab89, 0x98ba_dcfe, 0x1032_5476]

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = chunk + i * 4
                x[i] = UInt32(msg[o]) | UInt32(msg[o + 1]) << 8 | UInt32(msg[o + 2]) << 16 | UInt32(msg[o + 3]) << 24
            }

            var (a, b, c, d) = (h[0], h[1], h[2], h[3])
            var (aa, bb, cc, dd) = (h[0], h[1], h[2], h[3])

            for j in 0..<64 {
                let round = j / 16
                var t = a &+ f(round, b, c, d) &+ x[rL[j]] &+ kL[round]
                t = rol(t, sL[j])
                (a, b, c, d) = (d, t, b, c)

                var tt = aa &+ f(3 - round, bb, cc, dd) &+ x[rR[j]] &+ kR[round]
                tt = rol(tt, sR[j])
                (aa, bb, cc, dd) = (dd, tt, bb, cc)
            }

            let t = h[1] &+ c &+ dd
            h[1] = h[2] &+ d &+ aa
            h[2] = h[3] &+ a &+ bb
            h[3] = h[0] &+ b &+ cc
            h[0] = t
        }

        var digest = [UInt8]()
        digest.reserveCapacity(16)
        for word in h {
            for i in 0..<4 { digest.append(UInt8((word >> (8 * UInt32(i))) & 0xff)) }
        }
        return digest
    }
}
