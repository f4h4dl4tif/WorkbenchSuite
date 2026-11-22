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

    /// Fetches the newest catalog.json from the launcher repo so new tools appear without a launcher update.
    func remoteCatalog(owner: String, repo: String) async -> Catalog? {
        guard !owner.isEmpty, !repo.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/catalog.json")
        else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url, accept: "application/vnd.github.raw+json")),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The request used to download an asset. With a token, go through the API URL so private assets work.
    func downloadRequest(for asset: Asset) -> URLRequest {
        if let token, !token.isEmpty {
            return request(asset.apiURL, accept: "application/octet-stream")
        }
        return request(asset.browserDownloadURL, accept: "application/octet-stream")
    }
}

/// Stores the optional GitHub token in the login keychain, never in preferences.
enum TokenStore {
    private static let service = "app.workbenchsuite.launcher.github"

    static func load() -> String? {
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
