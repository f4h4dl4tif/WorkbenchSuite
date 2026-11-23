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
    @Published var alert: String?

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
        scanInstalled()
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

    func scanInstalled() {
        var found: [String: InstalledApp] = [:]
        for app in apps { if let i = Installer.locate(app) { found[app.id] = i } }
        installed = found
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let gh = github
        if let remote = await gh.remoteCatalog(owner: catalog.owner, repo: catalog.launcherRepo), !remote.apps.isEmpty {
            catalog = remote
        }
        scanInstalled()

        let owner = catalog.owner
        await withTaskGroup(of: (String, Result<Release, Error>).self) { group in
            for app in apps {
                group.addTask { (app.id, await Result(asyncCatching: { try await gh.latestRelease(owner: owner, repo: app.repo) })) }
            }
            for await (id, result) in group {
                switch result {
                case .success(let r): releases[id] = r; releaseErrors[id] = nil
                case .failure(let e): releaseErrors[id] = e.localizedDescription
                }
            }
        }

        if let own = try? await gh.latestRelease(owner: owner, repo: catalog.launcherRepo),
           let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           Version.isNewer(own.version, than: mine) {
            launcherUpdate = own
        }
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
        guard let release = releases[app.id], let asset = release.installAsset else {
            return "\(app.name) has no macOS download yet."
        }
        if !app.minOSSatisfied {
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
        } catch Installer.Failure.command(let message) where message.contains("Permission denied") || message.contains("Operation not permitted") {
            jobs[app.id] = nil
            return "\(app.name): couldn't write to \(location.path). Allow Workbench under System Settings › Privacy & Security › App Management, choose ~/Applications in Settings, or install from the release page."
        } catch let error as CocoaError where [.fileWriteNoPermission, .fileReadNoPermission].contains(error.code) {
            jobs[app.id] = nil
            return "\(app.name): couldn't replace it in \(location.path), so the current version was kept. Allow Workbench under System Settings › Privacy & Security › App Management, or choose ~/Applications in Settings."
        } catch {
            jobs[app.id] = nil
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
