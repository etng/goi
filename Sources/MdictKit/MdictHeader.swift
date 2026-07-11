import Foundation

public struct MdictHeader {
    public let attributes: [String: String]
    public let version: Double
    public let encrypted: Int
    public let codec: TextCodec
    /// True for MDD resource archives (header tag Library_Data).
    public let isResource: Bool

    public var title: String? { attributes["Title"].map(Self.unescape) }
    public var summary: String? { attributes["Description"].map(Self.unescape) }
    public var keyCaseSensitive: Bool { attributes["KeyCaseSensitive"] == "Yes" }
    public var stripKey: Bool { attributes["StripKey"] == "Yes" }

    init(xml: String, isResource declaredResource: Bool) throws {
        var attrs: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        let ns = xml as NSString
        for m in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            attrs[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        attributes = attrs

        guard let verString = attrs["GeneratedByEngineVersion"], let ver = Double(verString) else {
            throw MdictError.corrupted("missing GeneratedByEngineVersion in header")
        }
        guard ver < 3.0 else {
            throw MdictError.unsupportedVersion("MDX engine version \(verString) (v3 not yet supported)")
        }
        version = ver

        switch attrs["Encrypted"] ?? "0" {
        case "", "No": encrypted = 0
        case "Yes": encrypted = 1
        case let s: encrypted = Int(s) ?? 0
        }

        let resource = declaredResource || xml.contains("<Library_Data")
        isResource = resource
        codec = TextCodec.resolve(name: attrs["Encoding"] ?? "", isResource: resource)
    }

    static func unescape(_ s: String) -> String {
        var out = s
        for (entity, ch) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: ch)
        }
        return out
    }
}
