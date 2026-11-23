import AppKit
import Foundation

/// Downloads a release asset and puts the app in Applications.
/// Handles .dmg (mount and copy), .zip (extract and copy) and .pkg (hand to macOS Installer).
enum Installer {
    enum Outcome { case installed(URL), handedToInstaller }

    enum Failure: LocalizedError {
        case noAsset, appNotFound(String), command(String), cancelled(String), blockedByMacOS(String)
        var errorDescription: String? {
            switch self {
            case .cancelled(let name): return "\(name) wasn't changed because the password request was cancelled."
            case .blockedByMacOS(let name): return "macOS blocked Workbench from changing \(name). Allow Workbench under System Settings › Privacy & Security › App Management, then try again."
            case .noAsset: return "This release has no macOS download."
            case .appNotFound(let name): return "Couldn't find \(name) inside the download."
            case .command(let message): return message
            }
        }
    }

    static func install(app: SuiteApp, asset: Asset, github: GitHub, location: URL,
                        progress: @escaping @Sendable (Double?) -> Void) async throws -> Outcome {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var keepWork = false
        defer { if !keepWork { try? FileManager.default.removeItem(at: work) } }

        let file = try await Downloader(destination: work.appendingPathComponent(asset.name), progress: progress)
            .download(github.downloadRequest(for: asset))
        progress(nil)

        let source: URL
        switch file.pathExtension.lowercased() {
        case "pkg":
            keepWork = true   // Installer.app reads the package after we return
            return try await openPackage(file)
        case "zip":
            let out = work.appendingPathComponent("unzipped", isDirectory: true)
            try run("/usr/bin/ditto", ["-x", "-k", file.path, out.path])
            if let found = find(app.app, in: out) {
                source = found
            } else if let pkg = findExtension("pkg", in: out) {
                keepWork = true
                return try await openPackage(pkg)
            } else { throw Failure.appNotFound(app.app) }
        case "dmg":
            let mount = work.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, file.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let found = find(app.app, in: mount) else { throw Failure.appNotFound(app.app) }
            // Copy out of the image before it is detached.
            let staged = work.appendingPathComponent(app.app)
            try run("/usr/bin/ditto", [found.path, staged.path])
            source = staged
        default:
            throw Failure.noAsset
        }

        let destination = try place(source, named: app.app, bundleId: app.bundleId, in: location)
        return .installed(destination)
    }

    /// Copies the app into place, replacing an older copy. Quits the running copy first.
    private static func place(_ source: URL, named name: String, bundleId: String, in location: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: location, withIntermediateDirectories: true)
        let destination = location.appendingPathComponent(name)

        // Quit the running copy so the new one is what runs afterwards. Some tools (desktop widgets
        // like Tickdesk and Calendesk) deliberately ignore a normal Quit, so fall back to a force quit.
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        if wasRunning {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) { running.terminate() }
            if !waitUntilQuit(bundleId, seconds: 4) {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) { running.forceTerminate() }
                _ = waitUntilQuit(bundleId, seconds: 4)
            }
        }

        // Swap in the new copy without ever leaving a half-deleted app behind: copy the new app next
        // to the old one, rename the old one aside, rename the new one into place, then discard the old
        // one. If any step fails, the old app is put back exactly as it was.
        let staging = location.appendingPathComponent(".\(name).workbench-new")
        let previous = location.appendingPathComponent(".\(name).workbench-old")
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: previous)
        let hadOld = fm.fileExists(atPath: destination.path)
        do {
            do {
                try run("/usr/bin/ditto", [source.path, staging.path])
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
            do {
                if hadOld { try fm.moveItem(at: destination, to: previous) }
                try fm.moveItem(at: staging, to: destination)
            } catch {
                if hadOld, !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: previous, to: destination) }
                try? fm.removeItem(at: staging)
                throw error
            }
        } catch where Permission.kind(of: error) == .needsAdmin {
            // The folder or the old copy belongs to another user (apps installed from a .pkg are owned by
            // root). Ask for an administrator password, for this one app only, and do the swap that way.
            try Permission.replaceAsAdmin(source: source, destination: destination, previous: previous,
                                          appName: (name as NSString).deletingPathExtension, folder: location)
        } catch where Permission.kind(of: error) == .blockedByMacOS {
            throw Failure.blockedByMacOS((name as NSString).deletingPathExtension)
        }
        if hadOld, fm.fileExists(atPath: previous.path), (try? fm.removeItem(at: previous)) == nil {
            // The old copy belongs to root (installed from a .pkg). The new one is already in place, so
            // ask once to clear the old one away; if that's declined, put it in the Bin if possible.
            do { try Permission.removeAsAdmin(previous, reason: "remove the previous version of \((name as NSString).deletingPathExtension)") }
            catch { try? fm.trashItem(at: previous, resultingItemURL: nil) }
        }
        // Downloads made by the launcher aren't quarantined, but clear it in case the archive carried it.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        // Bring it back if it was running, now on the new version (in the background).
        if wasRunning {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in }
        }
        return destination
    }

    private static func waitUntilQuit(_ bundleId: String, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    private static func openPackage(_ pkg: URL) async throws -> Outcome {
        _ = try? run("/usr/bin/xattr", ["-d", "com.apple.quarantine", pkg.path])
        let config = NSWorkspace.OpenConfiguration()
        let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
        _ = try await NSWorkspace.shared.open([pkg], withApplicationAt: installer, configuration: config)
        return .handedToInstaller
    }

    private static func find(_ name: String, in folder: URL) -> URL? {
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = e?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        // Fall back to the only .app in the archive, if there is exactly one.
        return findExtension("app", in: folder)
    }

    private static func findExtension(_ ext: String, in folder: URL) -> URL? {
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = all?.nextObject() as? URL {
            if url.pathExtension == ext { return url }
        }
        return nil
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw Failure.command("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    // MARK: - Installed apps

    /// Finds an installed copy of a tool anywhere on the Mac, preferring Applications.
    /// Sources: the usual Applications folders, every copy LaunchServices knows about, running apps,
    /// and Spotlight results passed in by the caller.
    static func locate(_ app: SuiteApp, extra: [URL] = []) -> InstalledApp? {
        let fm = FileManager.default
        #if DEBUG
        // Test mode: only look in the throwaway folder (plus test extras) so tests never touch real installs.
        if let root = TestMode.root {
            let url = root.appendingPathComponent(app.app)
            if fm.fileExists(atPath: url.path) { return InstalledApp(url: url, version: version(of: url) ?? "?", inApplications: true) }
            let others = extra.filter { fm.fileExists(atPath: $0.path) && bundleId(of: $0) == app.bundleId }
            return others.first.map { InstalledApp(url: $0, version: version(of: $0) ?? "?", inApplications: false) }
        }
        #endif
        let home = fm.homeDirectoryForCurrentUser
        let appFolders = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var candidates: [URL] = []
        for folder in appFolders {
            candidates.append(folder.appendingPathComponent(app.app))
            candidates.append(folder.appendingPathComponent("Utilities").appendingPathComponent(app.app))
        }
        candidates += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleId)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).compactMap(\.bundleURL)
        candidates += running
        candidates += extra

        var seen = Set<String>()
        var copies: [InstalledApp] = []
        for url in candidates {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(path).inserted, fm.fileExists(atPath: path), isUsableLocation(path, home: home.path),
                  bundleId(of: url) == app.bundleId else { continue }
            let inApps = appFolders.contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
            copies.append(InstalledApp(url: URL(fileURLWithPath: path), version: version(of: url) ?? "?", inApplications: inApps))
        }
        let runningPaths = Set(running.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        // Applications first; then a copy that's running right now; then the newest version.
        return copies.max { a, b in
            if a.inApplications != b.inApplications { return !a.inApplications }
            let ar = runningPaths.contains(a.url.path), br = runningPaths.contains(b.url.path)
            if ar != br { return !ar }
            return Version.isNewer(b.version, than: a.version)
        }
    }

    /// Skips copies that aren't really "installed": mounted disk images, the Bin, temporary folders,
    /// SwiftPM debug bundles, apps nested inside other apps, and Workbench's own staging copies.
    static func isUsableLocation(_ path: String, home: String) -> Bool {
        let blocked = ["/Volumes/", "/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/", home + "/.Trash/", "/.Trash/"]
        if blocked.contains(where: { path.hasPrefix($0) }) || path.contains("/.Trashes/") { return false }
        if path.contains("/.build/") || path.contains(".workbench-new") || path.contains(".workbench-old") { return false }
        // An .app inside another .app's Contents (helpers, login items) isn't the tool itself.
        let inner = (path as NSString).deletingLastPathComponent
        if inner.contains(".app/") { return false }
        return true
    }

    static func bundleId(of url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    static func version(of url: URL) -> String? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// One Spotlight query for every tool's bundle ID; returns all matching app bundles.
    static func spotlightCopies(of bundleIds: [String]) -> [URL] {
        guard !bundleIds.isEmpty else { return [] }
        let query = bundleIds.map { "kMDItemCFBundleIdentifier == '\($0)'" }.joined(separator: " || ")
        guard let out = try? run("/usr/bin/mdfind", ["-0", query]) else { return [] }
        return out.split(separator: "\0").map { URL(fileURLWithPath: String($0)) }.filter { $0.pathExtension == "app" }
    }
}

/// URLSession download with progress, written into a known file name.
final class Downloader: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let destination: URL
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    init(destination: URL, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(_ request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            result = .failure(Installer.Failure.command("Download failed (HTTP \(code))"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(error) }
    }

    /// GitHub redirects asset downloads to a storage host that rejects our Authorization header.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host != task.originalRequest?.url?.host {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(with: result ?? .failure(Installer.Failure.command("Download failed"))) }
        continuation = nil
    }
}
