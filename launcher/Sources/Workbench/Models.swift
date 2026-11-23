import Foundation

// MARK: - Catalog (catalog.json, shared with the website)

struct Catalog: Codable {
    var suite: String
    var owner: String
    var launcherRepo: String
    var categories: [String]
    var apps: [SuiteApp]

    /// The catalog bundled inside the app. The launcher also tries the latest copy from GitHub.
    static func bundled() -> Catalog {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return Catalog(suite: "Workbench Suite", owner: "", launcherRepo: "", categories: [], apps: []) }
        return catalog
    }
}

struct SuiteApp: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let repo: String
    let app: String          // bundle name in /Applications, e.g. "Wattline.app"
    let bundleId: String
    let category: String
    let minOS: String
    let tagline: String
    let description: String

    func repoURL(owner: String) -> URL { URL(string: "https://github.com/\(owner)/\(repo)")! }

    var minOSSatisfied: Bool {
        let major = Int(minOS) ?? 0
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= major
    }
}

// MARK: - GitHub releases

struct Release: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, htmlURL = "html_url", publishedAt = "published_at", assets
    }

    var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }

    /// A release known only by its tag (from the website fallback); assets are fetched at install time.
    static func tagOnly(_ tag: String, owner: String, repo: String) -> Release {
        Release(tagName: tag, name: nil, body: nil,
                htmlURL: URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)")!,
                publishedAt: nil, assets: [])
    }

    /// The best asset for installing: a disk image, then a zip, then an installer package.
    var installAsset: Asset? {
        let mac = assets.filter { !$0.name.localizedCaseInsensitiveContains("windows") }
        return mac.first { $0.name.hasSuffix(".dmg") }
            ?? mac.first { $0.name.hasSuffix(".zip") }
            ?? mac.first { $0.name.hasSuffix(".pkg") }
    }
}

struct Asset: Codable {
    let name: String
    let size: Int
    let browserDownloadURL: URL
    let apiURL: URL

    enum CodingKeys: String, CodingKey {
        case name, size, browserDownloadURL = "browser_download_url", apiURL = "url"
    }
}

// MARK: - Versions

enum Version {
    /// Numeric comparison of dotted versions: "1.10" > "1.9", "1.0" == "1.0.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

// MARK: - Per-app state shown in the UI

struct InstalledApp {
    let url: URL
    let version: String
}

enum AppState: Equatable {
    case checking
    case unavailable(String)               // no release published yet, or offline
    case notInstalled
    case installed(String)
    case updateAvailable(from: String, to: String)
    case working(String, Double?)          // label, progress 0...1 (nil = indeterminate)
    case queued(Int)                       // waiting in the update queue (1 = next)
}
