import Foundation
import Security

/// Reads releases from the GitHub REST API. Unauthenticated calls work for public repos
/// (60 requests/hour); an optional personal access token raises the limit and reaches private repos.
struct GitHub {
    var token: String?

    enum Failure: LocalizedError {
        case noRelease, rateLimited, http(Int)
        var errorDescription: String? {
            switch self {
            case .noRelease: return "No release published yet"
            case .rateLimited: return "GitHub rate limit reached. Try again later or add a token in Settings."
            case .http(let code): return "GitHub returned HTTP \(code)"
            }
        }
    }

    func request(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("WorkbenchLauncher", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func latestRelease(owner: String, repo: String) async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(for: request(url))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 404: throw Failure.noRelease
        case 403, 429: throw Failure.rateLimited
        default: throw Failure.http(code)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Release.self, from: data)
    }

    /// Result of a conditional "latest release" request.
    enum Fetch {
        case release(Release, etag: String?)
        case notModified
    }

    struct RateInfo { var remaining: Int?; var reset: Date? }

    #if DEBUG
    /// Counts API requests in tests; WORKBENCH_TEST_RATELIMIT=1 makes every API call act rate limited.
    nonisolated(unsafe) static var apiRequestCount = 0
    nonisolated(unsafe) static var notModifiedCount = 0
    nonisolated(unsafe) static var lastSentETag: String?
    static var simulateRateLimit: Bool { ProcessInfo.processInfo.environment["WORKBENCH_TEST_RATELIMIT"] == "1" }
    #endif

    /// Latest release with If-None-Match. Reports GitHub's remaining rate limit through `rate`.
    func fetchLatest(owner: String, repo: String, etag: String?) async throws -> (Fetch, RateInfo) {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var r = request(url)
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        r.cachePolicy = .reloadIgnoringLocalCacheData
        #if DEBUG
        GitHub.apiRequestCount += 1
        GitHub.lastSentETag = etag
        if GitHub.simulateRateLimit { throw RateLimitHit(rate: RateInfo(remaining: 0, reset: Date().addingTimeInterval(20 * 60))) }
        #endif
        let (data, response) = try await URLSession.shared.data(for: r)
        let http = response as? HTTPURLResponse
        let rate = RateInfo(remaining: http?.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init),
                            reset: http?.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
        switch http?.statusCode ?? 0 {
        case 200: break
        case 304:
            #if DEBUG
            GitHub.notModifiedCount += 1
            #endif
            return (.notModified, rate)
        case 404: throw Failure.noRelease
        case 403, 429: throw RateLimitHit(rate: rate)
        case let code: throw Failure.http(code)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (.release(try decoder.decode(Release.self, from: data), etag: http?.value(forHTTPHeaderField: "ETag")), rate)
    }

    struct RateLimitHit: LocalizedError {
        var rate: RateInfo
        var errorDescription: String? { Failure.rateLimited.errorDescription }
    }

    /// The latest version from the regular website (github.com/…/releases/latest redirects to the tag).
    /// This isn't part of the API, so it works when the API limit is used up. It has no download list,
    /// so the launcher fetches the assets from the API only when you actually install.
    func latestTagFromWebsite(owner: String, repo: String) async -> String? {
        guard let url = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest") else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "HEAD"
        r.setValue("WorkbenchLauncher", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: r),
              let final = response.url, final.pathComponents.contains("tag"),
              let tag = final.pathComponents.last, tag != "latest" else { return nil }
        return tag.removingPercentEncoding ?? tag
    }

    /// Finds a download for a release known only by its tag, without the API: tries the file names the
    /// suite's packaging scripts produce on github.com/<owner>/<repo>/releases/download/<tag>/.
    func guessAsset(owner: String, repo: String, tag: String) async -> Asset? {
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let names = ["\(repo)-\(version).dmg", "\(repo)-\(version)-AppleSilicon.dmg",
                     "\(repo)-\(version).zip", "\(repo)-\(version).pkg"]
        for name in names {
            guard let url = URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(name)") else { continue }
            var r = URLRequest(url: url)
            r.httpMethod = "HEAD"
            r.setValue("WorkbenchLauncher", forHTTPHeaderField: "User-Agent")
            if let (_, response) = try? await URLSession.shared.data(for: r),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let size = Int(http.expectedContentLength)
                return Asset(name: name, size: max(size, 0), browserDownloadURL: url, apiURL: url)
            }
        }
        return nil
    }

    /// Fetches the newest catalog.json from the launcher repo so new tools appear without a launcher update.
    func remoteCatalog(owner: String, repo: String) async -> Catalog? {
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        // Without a token, read it from raw.githubusercontent.com: it isn't part of the API rate limit.
        if token?.isEmpty ?? true, let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/catalog.json") {
            var r = URLRequest(url: raw)
            r.setValue("WorkbenchLauncher", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: r),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let catalog = try? JSONDecoder().decode(Catalog.self, from: data) { return catalog }
            return nil
        }
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/catalog.json") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url, accept: "application/vnd.github.raw+json")),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The request used to download an asset. With a token, go through the API URL so private assets work.
    func downloadRequest(for asset: Asset) -> URLRequest {
        if let token, !token.isEmpty, asset.apiURL.host == "api.github.com" {
            return request(asset.apiURL, accept: "application/octet-stream")
        }
        return request(asset.browserDownloadURL, accept: "application/octet-stream")
    }
}

/// Stores the optional GitHub token in the login keychain, never in preferences.
enum TokenStore {
    private static let service = "app.workbenchsuite.launcher.github"

    static func load() -> String? {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["WORKBENCH_TEST_TOKEN"], !t.isEmpty { return t }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
