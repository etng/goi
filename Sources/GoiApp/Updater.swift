import Foundation

/// Update check against GitHub Releases. The release CI publishes a
/// `v<SemVer>` tag with a Goi.zip asset; here we compare the latest tag
/// to the running CFBundleShortVersionString and point the user at it.
///
/// Deliberately not Sparkle: the app is ad-hoc signed (no Developer ID /
/// notarization), so silent in-place replacement would trip Gatekeeper.
/// A guided download is the honest path for open-source distribution.
enum Updater {
    static let repo = "etng/goi"

    struct Release {
        let version: String        // without leading v
        let htmlURL: String
        let downloadURL: String?
        let notes: String
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// SemVer-ish compare (numeric core only; pre-release tags sort earlier).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        // equal cores: a pre-release (has '-') is older than the release
        let aPre = candidate.contains("-"), bPre = current.contains("-")
        return !aPre && bPre
    }

    enum CheckResult {
        case upToDate
        case available(Release)
        case failed(String)
    }

    static func check(completion: @escaping (CheckResult) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Goi/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let finish = { (result: CheckResult) in DispatchQueue.main.async { completion(result) } }
            if let error {
                finish(.failed(error.localizedDescription))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                finish(.failed("仓库还没有发布任何版本"))
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                finish(.failed("无法解析 GitHub 发布信息"))
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = obj["assets"] as? [[String: Any]] ?? []
            let zipURL = assets
                .first { ($0["name"] as? String)?.hasSuffix(".zip") == true }?["browser_download_url"] as? String
            let release = Release(
                version: version,
                htmlURL: obj["html_url"] as? String ?? "https://github.com/\(repo)/releases",
                downloadURL: zipURL,
                notes: obj["body"] as? String ?? ""
            )
            finish(isNewer(version, than: currentVersion) ? .available(release) : .upToDate)
        }.resume()
    }

    // MARK: - Automatic check (throttled once per day)

    private static let lastCheckKey = "lastUpdateCheck"

    static func checkOnLaunchIfDue(onUpdate: @escaping (Release) -> Void) {
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > 86400 else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        check { result in
            if case .available(let release) = result { onUpdate(release) }
        }
    }
}
