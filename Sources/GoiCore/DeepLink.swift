import Foundation

/// The small, read-only surface that other apps may invoke through Goi's
/// custom URL scheme. Keep parsing here, away from AppKit lifecycle code, so
/// every external value is validated before it can affect the application.
public enum GoiDeepLink: Equatable, Sendable {
    case search(word: String)

    public static let maximumSearchLength = 256

    public static func parse(_ url: URL, expectedScheme: String) -> GoiDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == expectedScheme.lowercased(),
              components.host?.lowercased() == "search",
              components.path.isEmpty || components.path == "/",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "word",
              let rawWord = queryItems[0].value else {
            return nil
        }

        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty,
              word.count <= maximumSearchLength,
              !word.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return .search(word: word)
    }
}
