import Foundation

/// Remembers the last release seen for each repo, with GitHub's ETag, so the launcher can:
/// - show results instantly at launch and offline,
/// - skip repos it checked recently (no request at all),
/// - ask GitHub "has it changed?" with If-None-Match (a 304 answer doesn't count against an
///   authenticated rate limit), and
/// - keep showing saved results when GitHub's rate limit is reached instead of an error.
struct ReleaseCache: Codable {
    struct Entry: Codable {
        var release: Release
        var etag: String?
        var fetchedAt: Date
        /// True when the version came from the website fallback and the assets still need fetching.
        var partial: Bool = false
    }

    var entries: [String: Entry] = [:]       // key: repo name
    var rateRemaining: Int?
    var rateReset: Date?

    /// Automatic checks skip a repo checked within this long. "Check for Updates" always asks.
    static let freshFor: TimeInterval = 30 * 60

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["WORKBENCH_TEST_CACHE_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("release-cache.json")
        }
        #endif
        return base.appendingPathComponent("Workbench", isDirectory: true).appendingPathComponent("release-cache.json")
    }

    static func load() -> ReleaseCache {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? decoder.decode(ReleaseCache.self, from: data) else { return ReleaseCache() }
        return cache
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func isFresh(_ repo: String, now: Date = Date()) -> Bool {
        guard let e = entries[repo], !e.partial else { return false }
        return now.timeIntervalSince(e.fetchedAt) < Self.freshFor
    }

    /// True while GitHub has told us the limit is used up and hasn't reset yet.
    func isRateLimited(now: Date = Date()) -> Bool {
        guard let remaining = rateRemaining, let reset = rateReset else { return false }
        return remaining <= 0 && reset > now
    }
}
