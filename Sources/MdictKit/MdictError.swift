import Foundation

public enum MdictError: Error, CustomStringConvertible {
    case truncated(String)
    case badChecksum(String)
    case unsupportedVersion(String)
    case unsupportedFeature(String)
    case corrupted(String)

    public var description: String {
        switch self {
        case .truncated(let m): return "truncated: \(m)"
        case .badChecksum(let m): return "bad checksum: \(m)"
        case .unsupportedVersion(let m): return "unsupported version: \(m)"
        case .unsupportedFeature(let m): return "unsupported feature: \(m)"
        case .corrupted(let m): return "corrupted: \(m)"
        }
    }
}
