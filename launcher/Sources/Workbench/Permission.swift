import AppKit
import Foundation

/// Handles the cases where Workbench (running as you) isn't allowed to replace or delete an app:
/// - The app or its folder belongs to another user. Apps installed from a .pkg are owned by root, and
///   standard (non-admin) accounts can't write to /Applications. Workbench asks for an administrator
///   password with the standard macOS dialog and runs a fixed command for that one app path only.
///   The new copy is then handed back to you, so later updates won't need a password.
/// - macOS itself refuses ("Operation not permitted"): App Management privacy protection or a locked
///   file. A password can't override that, so Workbench points you to System Settings instead.
enum Permission {
    enum Kind { case needsAdmin, blockedByMacOS, other }

    static let appManagementSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    static func kind(of error: Error) -> Kind {
        if case Installer.Failure.command(let message) = error {
            if message.contains("Permission denied") { return .needsAdmin }
            if message.contains("Operation not permitted") { return .blockedByMacOS }
            return .other
        }
        let ns = error as NSError
        let posix: Int? = ns.domain == NSPOSIXErrorDomain ? ns.code
            : (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        switch posix {
        case Int(EACCES): return .needsAdmin
        case Int(EPERM): return .blockedByMacOS
        default:
            // Foundation sometimes reports a plain "no permission" without the POSIX reason.
            if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError { return .needsAdmin }
            return .other
        }
    }

    /// Replace `destination` with `source` as administrator. Restores the old app if anything fails.
    static func replaceAsAdmin(source: URL, destination: URL, previous: URL, appName: String, folder: URL) throws {
        let d = q(destination.path), p = q(previous.path), s = q(source.path)
        let owner = "\(getuid()):\(getgid())"
        let script = """
        /bin/rm -rf \(p); \
        if [ -e \(d) ]; then /bin/mv \(d) \(p) || exit 1; fi; \
        if /usr/bin/ditto \(s) \(d); then \
        /usr/sbin/chown -R \(owner) \(d); /usr/bin/xattr -dr com.apple.quarantine \(d) 2>/dev/null; /bin/rm -rf \(p); exit 0; \
        else /bin/rm -rf \(d); if [ -e \(p) ]; then /bin/mv \(p) \(d); fi; exit 1; fi
        """
        try runAsAdmin(script, prompt: "Workbench needs your password to update \(appName) in \(folder.path).", appName: appName)
    }

    /// Delete one app bundle (the old copy left beside the new one) as administrator.
    static func removeAsAdmin(_ url: URL, reason: String) throws {
        guard url.lastPathComponent.hasSuffix(".app") || url.lastPathComponent.hasSuffix(".workbench-old") else { return }
        try runAsAdmin("/bin/rm -rf \(q(url.path))", prompt: "Workbench needs your password to \(reason).",
                       appName: url.deletingPathExtension().lastPathComponent)
    }

    /// Move one app to your Bin as administrator (for apps owned by root), handing it back to you.
    static func trashAsAdmin(_ url: URL, appName: String) throws {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        var target = trash.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Date().formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted)).replacingOccurrences(of: ":", with: "")
            target = trash.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(stamp).app")
        }
        let script = "/bin/mv \(q(url.path)) \(q(target.path)) && /usr/sbin/chown -R \(getuid()):\(getgid()) \(q(target.path))"
        try runAsAdmin(script, prompt: "Workbench needs your password to move \(appName) to the Bin.", appName: appName)
    }

    /// Runs a fixed shell command with administrator rights through the standard macOS password dialog.
    private static func runAsAdmin(_ script: String, prompt: String, appName: String) throws {
        #if DEBUG
        // Tests: run the exact same command without elevation, so the logic can be checked unattended.
        if ProcessInfo.processInfo.environment["WORKBENCH_TEST_ADMIN_AS_USER"] == "1" {
            print("[admin] \(prompt)"); fflush(stdout)
            try Installer.run("/bin/sh", ["-c", script]); return
        }
        #endif
        let apple = appleScript(script, prompt: prompt)
        do {
            try Installer.run("/usr/bin/osascript", ["-e", apple])
        } catch Installer.Failure.command(let message) where message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            throw Installer.Failure.cancelled(appName)
        }
    }

    static func appleScript(_ script: String, prompt: String) -> String {
        "do shell script \"\(escapeAppleScript(script))\" with prompt \"\(escapeAppleScript(prompt))\" with administrator privileges"
    }

    #if DEBUG
    /// The exact AppleScript a replace would run, for syntax checks in tests.
    static func debugReplaceAppleScript(source: URL, destination: URL, previous: URL) -> String {
        let d = q(destination.path), p = q(previous.path), s = q(source.path)
        return appleScript("/bin/rm -rf \(p); /bin/mv \(d) \(p); /usr/bin/ditto \(s) \(d)", prompt: "Workbench needs your password to update Glint's \"test\" in /Applications.")
    }
    #endif

    /// Single-quotes a path for /bin/sh.
    static func q(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
