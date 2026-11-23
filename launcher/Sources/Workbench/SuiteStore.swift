import AppKit
import SwiftUI

@MainActor
final class SuiteStore: ObservableObject {
    @Published private(set) var catalog = Catalog.bundled()
    @Published private(set) var releases: [String: Release] = [:]
    @Published private(set) var releaseErrors: [String: String] = [:]
    @Published private(set) var installed: [String: InstalledApp] = [:]
    @Published private(set) var jobs: [String: (label: String, progress: Double?)] = [:]
    /// Tools waiting to be installed or updated, in order. One runs at a time; the rest wait here.
    @Published private(set) var queue: [String] = []
    /// Progress of the current queue run, for "Updating 2 of 3…".
    @Published private(set) var queueRun: (done: Int, total: Int)?
    private var queueWorker: Task<Void, Never>?
    private var queueFailures: [String] = []
    /// Failures from the last finished queue run (kept for the summary and for tests).
    @Published private(set) var lastQueueFailures: [String] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var launcherUpdate: Release?
    /// When GitHub's API limit is used up: the time it resets. Saved results are shown meanwhile.
    @Published private(set) var rateLimitedUntil: Date?
    /// When the releases were last confirmed with GitHub.
    @Published private(set) var lastChecked: Date?
    private var cache = ReleaseCache.load()
    @Published var alert: String?
    /// The alert offers to open System Settings › App Management (macOS blocked changing an app).
    @Published var needsAppManagement = false

    @AppStorage("installLocation") var installLocation = InstallLocation.applications.rawValue
    @AppStorage("checkOnLaunch") var checkOnLaunch = true

    enum InstallLocation: String, CaseIterable, Identifiable {
        case applications, userApplications
        var id: String { rawValue }
        var url: URL {
            switch self {
            case .applications: return URL(fileURLWithPath: "/Applications")
            case .userApplications: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            }
        }
        var title: String { self == .applications ? "/Applications (all users)" : "~/Applications (just me)" }
    }

    private var github: GitHub { GitHub(token: TokenStore.load()) }
    private var observers: [NSObjectProtocol] = []

    init() {
        // Show what we knew last time straight away (also works offline).
        for app in catalog.apps { if let e = cache.entries[app.repo] { releases[app.id] = e.release } }
        lastChecked = cache.entries.values.map(\.fetchedAt).max()
        if cache.isRateLimited() { rateLimitedUntil = cache.rateReset }
        scanInstalled()
        Task { await scanWithSpotlight() }
        // Re-scan when the user returns to the launcher (they may have deleted or moved an app).
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scanInstalled() }
        })
    }

    var apps: [SuiteApp] { catalog.apps }

    func state(of app: SuiteApp) -> AppState {
        if let job = jobs[app.id] { return .working(job.label, job.progress) }
        if let i = queue.firstIndex(of: app.id) { return .queued(i + 1) }
        let latest = releases[app.id]
        if let local = installed[app.id] {
            if let latest, Version.isNewer(latest.version, than: local.version) {
                return .updateAvailable(from: local.version, to: latest.version)
            }
            return .installed(local.version)
        }
        if latest != nil { return .notInstalled }
        if let error = releaseErrors[app.id] { return .unavailable(error) }
        return isRefreshing ? .checking : .unavailable("Not checked yet")
    }

    var updatesAvailable: [SuiteApp] {
        apps.filter { if case .updateAvailable = state(of: $0) { return true }; return false }
    }

    // MARK: Refresh

    /// App bundles Spotlight found for the suite's bundle IDs (refreshed in the background).
    private var spotlightHits: [URL] = []

    func scanInstalled() {
        var found: [String: InstalledApp] = [:]
        for app in apps { if let i = Installer.locate(app, extra: spotlightHits) { found[app.id] = i } }
        installed = found
    }

    /// Asks Spotlight for every copy of every tool, then re-scans. Runs off the main thread.
    func scanWithSpotlight() async {
        #if DEBUG
        if TestMode.root != nil {
            // Tests: pretend Spotlight found the apps in WORKBENCH_TEST_ELSEWHERE (outside Applications).
            if let dir = ProcessInfo.processInfo.environment["WORKBENCH_TEST_ELSEWHERE"] {
                spotlightHits = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "app" }
            }
            scanInstalled(); return
        }
        #endif
        let ids = apps.map(\.bundleId)
        spotlightHits = await Task.detached(priority: .utility) { Installer.spotlightCopies(of: ids) }.value
        scanInstalled()
    }

    /// Checks GitHub for new releases.
    /// - Parameter force: false for automatic checks (launch): repos checked in the last 30 minutes
    ///   are skipped. true for "Check for Updates": every repo is asked, conditionally (ETag).
    func refresh(force: Bool = true) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; cache.save() }

        let gh = github
        if let remote = await gh.remoteCatalog(owner: catalog.owner, repo: catalog.launcherRepo), !remote.apps.isEmpty {
            catalog = remote
        }
        await scanWithSpotlight()

        let owner = catalog.owner
        let repos = apps.map(\.repo) + [catalog.launcherRepo]
        let due = repos.filter { force || !cache.isFresh($0) }
        let etags = Dictionary(uniqueKeysWithValues: due.map { ($0, cache.entries[$0]?.partial == true ? nil : cache.entries[$0]?.etag) })
        var limited = cache.isRateLimited()

        if !limited, !due.isEmpty {
            await withTaskGroup(of: (String, Result<(GitHub.Fetch, GitHub.RateInfo), Error>).self) { group in
                for repo in due {
                    let etag = etags[repo] ?? nil
                    group.addTask { (repo, await Result(asyncCatching: { try await gh.fetchLatest(owner: owner, repo: repo, etag: etag) })) }
                }
                for await (repo, result) in group {
                    switch result {
                    case .success(let (fetch, rate)):
                        note(rate)
                        switch fetch {
                        case .release(let r, let etag): cache.entries[repo] = .init(release: r, etag: etag, fetchedAt: Date())
                        case .notModified: cache.entries[repo]?.fetchedAt = Date()
                        }
                        setError(nil, for: repo)
                    case .failure(let hit as GitHub.RateLimitHit):
                        note(hit.rate, hitLimit: true)
                        limited = true
                    case .failure(let e):
                        if case GitHub.Failure.rateLimited = e { limited = true; noteLimitWithoutHeaders() }
                        else { setError(e.localizedDescription, for: repo) }
                    }
                }
            }
        }

        // Out of API requests: keep saved results, and learn new versions from the website instead.
        if limited {
            let missing = due.filter { !cache.isFresh($0) }
            await withTaskGroup(of: (String, String?).self) { group in
                for repo in missing { group.addTask { (repo, await gh.latestTagFromWebsite(owner: owner, repo: repo)) } }
                for await (repo, tag) in group {
                    guard let tag else {
                        if cache.entries[repo] == nil { setError(GitHub.Failure.rateLimited.localizedDescription, for: repo) }
                        continue
                    }
                    if let e = cache.entries[repo], e.release.tagName == tag {
                        cache.entries[repo]?.fetchedAt = Date()          // unchanged; keep full details
                    } else {
                        cache.entries[repo] = .init(release: .tagOnly(tag, owner: owner, repo: repo), etag: nil,
                                                    fetchedAt: Date(), partial: true)
                    }
                    setError(nil, for: repo)
                }
            }
        }

        rateLimitedUntil = cache.isRateLimited() ? cache.rateReset : nil
        for app in apps { if let e = cache.entries[app.repo] { releases[app.id] = e.release } }
        lastChecked = Date()

        if let own = cache.entries[catalog.launcherRepo]?.release,
           let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           Version.isNewer(own.version, than: mine) {
            launcherUpdate = own
        }
    }

    #if DEBUG
    func debugForget(_ repos: [String]) { for r in repos { cache.entries[r] = nil } }
    func debugExpireAll() { for k in cache.entries.keys { cache.entries[k]?.fetchedAt = .distantPast } }
    func debugClearRateLimit() { cache.rateRemaining = nil; cache.rateReset = nil }
    var debugCache: ReleaseCache { cache }
    #endif

    private func note(_ rate: GitHub.RateInfo, hitLimit: Bool = false) {
        if let r = rate.remaining {
            // Answers arrive out of order; within one limit window the lowest count is the true one.
            if !hitLimit, let reset = rate.reset, reset == cache.rateReset, let known = cache.rateRemaining {
                cache.rateRemaining = min(known, r)
            } else {
                cache.rateRemaining = hitLimit ? 0 : r
            }
        }
        else if hitLimit { cache.rateRemaining = 0 }
        if let reset = rate.reset { cache.rateReset = reset }
        else if hitLimit, cache.rateReset == nil || cache.rateReset! < Date() { cache.rateReset = Date().addingTimeInterval(15 * 60) }
    }

    private func noteLimitWithoutHeaders() { note(.init(remaining: 0, reset: nil), hitLimit: true) }

    private func setError(_ message: String?, for repo: String) {
        guard let app = apps.first(where: { $0.repo == repo }) else { return }
        releaseErrors[app.id] = message
    }

    /// The full release (with downloads) for an app. Uses the cache unless it only knows the tag.
    private func fullRelease(for app: SuiteApp) async throws -> Release {
        if let e = cache.entries[app.repo], !e.partial, !e.release.assets.isEmpty { return e.release }
        // Known only from the website while the API limit is used up: find the download by name.
        if let e = cache.entries[app.repo], e.partial, cache.isRateLimited(),
           let asset = await github.guessAsset(owner: catalog.owner, repo: app.repo, tag: e.release.tagName) {
            let r = e.release
            return Release(tagName: r.tagName, name: r.name, body: r.body, htmlURL: r.htmlURL, publishedAt: r.publishedAt, assets: [asset])
        }
        let (fetch, rate) = try await github.fetchLatest(owner: catalog.owner, repo: app.repo, etag: nil)
        note(rate)
        guard case .release(let r, let etag) = fetch else { throw GitHub.Failure.noRelease }
        cache.entries[app.repo] = .init(release: r, etag: etag, fetchedAt: Date())
        cache.save()
        releases[app.id] = r
        return r
    }

    // MARK: Actions

    /// Install or update one tool. It joins the queue, so it never runs alongside another install.
    func install(_ app: SuiteApp) async {
        enqueue([app])
        await queueWorker?.value
    }

    /// Update every tool that has an update, one after another, in the order shown.
    func updateAll() async {
        enqueue(updatesAvailable)
        await queueWorker?.value
    }

    var isQueueRunning: Bool { queueWorker != nil }

    /// Adds tools to the end of the queue (skipping any already queued or running) and starts it if idle.
    func enqueue(_ apps: [SuiteApp]) {
        let new = apps.map(\.id).filter { !queue.contains($0) && jobs[$0] == nil }
        guard !new.isEmpty else { return }
        queue.append(contentsOf: new)
        if let run = queueRun { queueRun = (run.done, run.total + new.count) } else { queueRun = (0, new.count) }
        guard queueWorker == nil else { return }
        queueFailures = []
        queueWorker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    /// Removes a tool that hasn't started yet from the queue.
    func dequeue(_ app: SuiteApp) {
        guard let i = queue.firstIndex(of: app.id) else { return }
        queue.remove(at: i)
        if let run = queueRun { queueRun = (run.done, max(run.done, run.total - 1)) }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let app = apps.first(where: { $0.id == id }) {
                if let failure = await performInstall(app) { queueFailures.append(failure) }
            }
            if let run = queueRun { queueRun = (run.done + 1, run.total) }
        }
        lastQueueFailures = queueFailures
        queueWorker = nil
        queueRun = nil
        scanInstalled()
        if queueFailures.count == 1 {
            alert = queueFailures[0]
        } else if queueFailures.count > 1 {
            alert = "\(queueFailures.count) tools couldn't be updated:\n\n" + queueFailures.joined(separator: "\n")
        }
        queueFailures = []
    }

    /// Downloads and installs one tool. Returns a message if it failed; never stops the queue.
    private func performInstall(_ app: SuiteApp) async -> String? {
        guard jobs[app.id] == nil else { return nil }
        jobs[app.id] = ("Preparing…", nil)
        let release: Release
        do { release = try await fullRelease(for: app) }
        catch let e where e is GitHub.RateLimitHit || { if case GitHub.Failure.rateLimited = e { return true }; return false }() {
            jobs[app.id] = nil
            let when = rateLimitedUntil.map { " after \($0.formatted(date: .omitted, time: .shortened))" } ?? " later"
            return "\(app.name): GitHub's download limit is used up. Try again\(when), or add a token in Settings."
        } catch {
            jobs[app.id] = nil
            return "\(app.name): \(error.localizedDescription)"
        }
        guard let asset = release.installAsset else {
            jobs[app.id] = nil
            return "\(app.name) has no macOS download yet."
        }
        if !app.minOSSatisfied {
            jobs[app.id] = nil
            return "\(app.name) needs macOS \(app.minOS) or later."
        }
        jobs[app.id] = ("Downloading…", 0)
        var location = (InstallLocation(rawValue: installLocation) ?? .applications).url
        #if DEBUG
        if let root = TestMode.root { location = root }
        #endif
        let id = app.id
        do {
            let outcome = try await Installer.install(app: app, asset: asset, github: github, location: location) { p in
                Task { @MainActor [weak self] in
                    guard self?.jobs[id] != nil else { return }
                    self?.jobs[id] = (p == nil ? "Installing…" : "Downloading…", p)
                }
            }
            jobs[app.id] = nil
            scanInstalled()
            if case .handedToInstaller = outcome {
                return "The \(app.name) installer is open. Follow its steps, then come back here."
            }
            return nil
        } catch let failure as Installer.Failure {
            jobs[app.id] = nil
            switch failure {
            case .blockedByMacOS: needsAppManagement = true; return failure.localizedDescription
            case .cancelled: return failure.localizedDescription
            default: return "\(app.name): \(failure.localizedDescription)"
            }
        } catch {
            jobs[app.id] = nil
            if Permission.kind(of: error) == .blockedByMacOS {
                needsAppManagement = true
                return Installer.Failure.blockedByMacOS(app.name).localizedDescription
            }
            return "\(app.name): \(error.localizedDescription)"
        }
    }

    func open(_ app: SuiteApp) {
        guard let url = installed[app.id]?.url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func reveal(_ app: SuiteApp) {
        guard let url = installed[app.id]?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func uninstall(_ app: SuiteApp) {
        guard let url = installed[app.id]?.url else { return }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId) { running.terminate() }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            scanInstalled()
        } catch where Permission.kind(of: error) == .needsAdmin {
            // Owned by root (installed from a .pkg): ask for a password to move just this app to the Bin.
            Task.detached { [weak self] in
                do {
                    try Permission.trashAsAdmin(url, appName: app.name)
                    await MainActor.run { self?.scanInstalled() }
                } catch {
                    await MainActor.run { self?.alert = "\(app.name) wasn't moved to the Bin: \(error.localizedDescription)" }
                }
            }
        } catch where Permission.kind(of: error) == .blockedByMacOS {
            needsAppManagement = true
            alert = Installer.Failure.blockedByMacOS(app.name).localizedDescription
        } catch {
            alert = "Couldn't move \(app.name) to the Bin: \(error.localizedDescription)"
        }
    }

    func repoURL(_ app: SuiteApp) -> URL { app.repoURL(owner: catalog.owner) }
    var suiteRepoURL: URL { URL(string: "https://github.com/\(catalog.owner)/\(catalog.launcherRepo)")! }

    func icon(for app: SuiteApp) -> NSImage {
        if let local = installed[app.id] { return NSWorkspace.shared.icon(forFile: local.url.path) }
        if let url = Bundle.main.url(forResource: app.repo, withExtension: "png", subdirectory: "Icons"),
           let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

private extension Result where Failure == Error {
    init(asyncCatching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
