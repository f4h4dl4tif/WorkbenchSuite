import AppKit
import Foundation

/// Downloads a release asset and puts the app in Applications.
/// Handles .dmg (mount and copy), .zip (extract and copy) and .pkg (hand to macOS Installer).
enum Installer {
    enum Outcome { case installed(URL), handedToInstaller }

    enum Failure: LocalizedError {
        case noAsset, appNotFound(String), command(String)
        var errorDescription: String? {
            switch self {
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

        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            running.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }

        let staging = location.appendingPathComponent(".\(name).workbench-new")
        try? fm.removeItem(at: staging)
        try run("/usr/bin/ditto", [source.path, staging.path])
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        // Downloads made by the launcher aren't quarantined, but clear it in case the archive carried it.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        return destination
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

    static func locate(_ app: SuiteApp) -> InstalledApp? {
        let fm = FileManager.default
        var candidates = [
            URL(fileURLWithPath: "/Applications").appendingPathComponent(app.app),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").appendingPathComponent(app.app),
        ]
        if let byId = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
            candidates.append(byId)
        }
        for url in candidates where fm.fileExists(atPath: url.path) {
            // Ignore copies still sitting inside a project's build folder.
            if url.path.contains("/build/") || url.path.contains("/.build/") || url.path.contains("/dist/") { continue }
            let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            let version = plist?["CFBundleShortVersionString"] as? String ?? "?"
            return InstalledApp(url: url, version: version)
        }
        return nil
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
