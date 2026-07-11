import Foundation

/// Decompressor for raw LZO1X streams as used by MDX/MDD compressed blocks
/// (block type 0x01). Port of minilzo's lzo1x_decompress_safe.
enum LZO {
    static func decompress(_ input: Data, decompressedSize: Int) throws -> Data {
        let src = [UInt8](input)
        var dst = [UInt8](repeating: 0, count: decompressedSize)
        let inLen = src.count
        var ip = 0
        var op = 0

        func fail(_ m: String) -> MdictError { .corrupted("lzo: \(m) (ip=\(ip), op=\(op))") }

        @inline(__always) func inByte() throws -> Int {
            guard ip < inLen else { throw fail("input overrun") }
            defer { ip += 1 }
            return Int(src[ip])
        }

        func copyLiterals(_ n: Int) throws {
            guard ip + n <= inLen else { throw fail("input overrun in literals") }
            guard op + n <= decompressedSize else { throw fail("output overrun in literals") }
            dst.replaceSubrange(op..<op + n, with: src[ip..<ip + n])
            ip += n
            op += n
        }

        // Matches may overlap themselves; copy strictly forward byte-by-byte.
        func copyMatch(from mPos: Int, length: Int) throws {
            guard mPos >= 0, mPos < op else { throw fail("lookbehind overrun") }
            guard op + length <= decompressedSize else { throw fail("output overrun in match") }
            var m = mPos
            for i in 0..<length {
                dst[op + i] = dst[m]
                m += 1
            }
            op += length
        }

        // reads the run-length extension: zero bytes add 255 each
        func extendedLength(base: Int) throws -> Int {
            var t = 0
            while true {
                let b = try inByte()
                if b == 0 { t += 255 } else { return t + base + b }
            }
        }

        enum State {
            case literalRun          // "top" of the main loop
            case firstLiteralRun     // right after a literal run
            case match(Int)          // interpret value as a match instruction
            case matchDone
        }

        var state: State = .literalRun

        // stream prologue: first byte > 17 encodes an initial literal run
        if inLen > 0, src[0] > 17 {
            let t = Int(src[0]) - 17
            ip = 1
            try copyLiterals(t)
            if t < 4 {
                state = .match(try inByte())
            } else {
                state = .firstLiteralRun
            }
        }

        while true {
            switch state {
            case .literalRun:
                var t = try inByte()
                if t >= 16 {
                    state = .match(t)
                    continue
                }
                if t == 0 { t = try extendedLength(base: 15) }
                try copyLiterals(t + 3)
                state = .firstLiteralRun

            case .firstLiteralRun:
                let t = try inByte()
                if t >= 16 {
                    state = .match(t)
                    continue
                }
                // short M2 match right after a literal run (distance base 0x801)
                var mPos = op - (1 + 0x0800)
                mPos -= t >> 2
                mPos -= try inByte() << 2
                try copyMatch(from: mPos, length: 3)
                state = .matchDone

            case .match(var t):
                if t >= 64 {
                    // M2: 3-byte to 8-byte match, 2-byte encoding
                    var mPos = op - 1
                    mPos -= (t >> 2) & 7
                    mPos -= try inByte() << 3
                    t = (t >> 5) - 1
                    try copyMatch(from: mPos, length: t + 2)
                    state = .matchDone
                } else if t >= 32 {
                    // M3: distance up to 16k
                    t &= 31
                    if t == 0 { t = try extendedLength(base: 31) }
                    let b0 = try inByte()
                    let b1 = try inByte()
                    let mPos = op - 1 - (b0 >> 2) - (b1 << 6)
                    try copyMatch(from: mPos, length: t + 2)
                    state = .matchDone
                } else if t >= 16 {
                    // M4: distance up to 48k; also encodes end-of-stream
                    var mPos = op - ((t & 8) << 11)
                    t &= 7
                    if t == 0 { t = try extendedLength(base: 7) }
                    let b0 = try inByte()
                    let b1 = try inByte()
                    mPos -= (b0 >> 2) + (b1 << 6)
                    if mPos == op {
                        // end marker
                        guard t == 1 else { throw fail("bad end marker") }
                        guard op == decompressedSize else { throw fail("size mismatch: \(op) != \(decompressedSize)") }
                        return Data(dst)
                    }
                    mPos -= 0x4000
                    try copyMatch(from: mPos, length: t + 2)
                    state = .matchDone
                } else {
                    // M1: 2-byte match after a match (no intervening literals)
                    var mPos = op - 1
                    mPos -= t >> 2
                    mPos -= try inByte() << 2
                    try copyMatch(from: mPos, length: 2)
                    state = .matchDone
                }

            case .matchDone:
                // low 2 bits of the second-to-last consumed byte give the
                // number of trailing literals before the next instruction
                guard ip >= 2 else { throw fail("dangling match") }
                let trailing = Int(src[ip - 2]) & 3
                if trailing == 0 {
                    state = .literalRun
                } else {
                    try copyLiterals(trailing)
                    state = .match(try inByte())
                }
            }
        }
    }
}
