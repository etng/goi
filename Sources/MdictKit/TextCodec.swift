import Foundation

/// Text encoding of keys and records, declared in the MDX header.
public enum TextCodec {
    case utf8
    case utf16le
    case other(String.Encoding, name: String)

    static func resolve(name: String, isResource: Bool) -> TextCodec {
        if isResource { return .utf16le } // MDD keys are always UTF-16LE
        switch name.uppercased() {
        case "", "UTF-8", "UTF8":
            return .utf8
        case "UTF-16", "UTF16", "UTF-16LE":
            return .utf16le
        case "GBK", "GB2312", "GB18030":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return .other(String.Encoding(rawValue: cf), name: name)
        case "BIG5", "BIG-5":
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return .other(String.Encoding(rawValue: cf), name: name)
        case "ISO8859-1", "ISO-8859-1", "LATIN1":
            return .other(.isoLatin1, name: name)
        default:
            return .other(.utf8, name: name) // best effort
        }
    }

    /// Width of the null terminator after key texts.
    var terminatorWidth: Int {
        if case .utf16le = self { return 2 }
        return 1
    }

    /// True when key-index text sizes count UTF-16 code units instead of bytes.
    var sizesAreCodeUnits: Bool {
        if case .utf16le = self { return true }
        return false
    }

    func decode(_ data: Data) -> String? {
        switch self {
        case .utf8:
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self) // lossy fallback
        case .utf16le:
            return String(data: data, encoding: .utf16LittleEndian)
        case .other(let encoding, _):
            return String(data: data, encoding: encoding)
        }
    }

    public var name: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16le: return "UTF-16LE"
        case .other(_, let name): return name
        }
    }
}
