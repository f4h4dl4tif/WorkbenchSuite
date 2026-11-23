#if DEBUG
import AppKit

/// Developer aid (DEBUG builds only).
///   WORKBENCH_TEST_ROOT=<dir>   look for and install tools only in <dir>, never /Applications.
///   --test-update-all           refresh, press "Update All" (the same store call the buttons make),
///                               log every state change, print a summary and quit.
@MainActor
enum TestMode {
    nonisolated static let root: URL? = ProcessInfo.processInfo.environment["WORKBENCH_TEST_ROOT"].map { URL(fileURLWithPath: $0) }

    /// --test-cache: checks how many API requests refreshes make, and the rate-limit fallback.
    static func runCacheTest(store: SuiteStore) async {
        let start = Date()
        func log(_ s: String) { print("[\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(s)"); fflush(stdout) }
        var ok = true
        func check(_ cond: Bool, _ msg: String) { ok = ok && cond; log("\(cond ? "PASS" : "FAIL") \(msg)") }
        let repoCount = store.apps.count + 1

        log("at launch, before any request: \(store.releases.count) releases shown from the saved cache")
        if CommandLine.arguments.contains("--expect-saved") {
            check(store.releases.count == store.apps.count, "a relaunch shows every release instantly from disk")
        }

        GitHub.apiRequestCount = 0
        await store.refresh(force: false)
        log("launch check: \(GitHub.apiRequestCount) API requests, \(store.releases.count) releases, remaining \(store.debugCache.rateRemaining.map(String.init) ?? "?")")

        GitHub.apiRequestCount = 0
        await store.refresh(force: false)
        check(GitHub.apiRequestCount == 0, "second automatic check within 30 min makes no API requests (made \(GitHub.apiRequestCount))")

        func coreRemaining() async -> Int? {   // GitHub's /rate_limit endpoint is free to call
            var r = URLRequest(url: URL(string: "https://api.github.com/rate_limit")!)
            if let t = TokenStore.load() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            guard let (data, _) = try? await URLSession.shared.data(for: r),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let core = (json["resources"] as? [String: Any])?["core"] as? [String: Any] else { return nil }
            return core["remaining"] as? Int
        }
        let before = await coreRemaining()
        GitHub.apiRequestCount = 0
        await store.refresh(force: true)
        let after = await coreRemaining()
        log("304 answers: \(GitHub.notModifiedCount), last ETag sent: \(GitHub.lastSentETag ?? "nil")")
        log("manual Check for Updates: \(GitHub.apiRequestCount) conditional requests; rate remaining \(before.map(String.init) ?? "?") -> \(after.map(String.init) ?? "?")")
        if let b = before, let a = after { check(b - a <= 1, "unchanged releases answered with 304 don't use up the limit (used \(b - a) of \(repoCount))") }

        // Simulate the limit being used up, with two repos never seen before.
        setenv("WORKBENCH_TEST_RATELIMIT", "1", 1)
        let forgotten = ["Juxta", "Kalam"]
        store.debugForget(forgotten)
        store.debugExpireAll()
        await store.refresh(force: true)
        check(store.releases.count == store.apps.count, "with the limit used up every tool still shows a release (\(store.releases.count)/\(store.apps.count))")
        check(store.rateLimitedUntil != nil, "the saved-results note is shown (until \(store.rateLimitedUntil.map { "\($0)" } ?? "nil"))")
        for r in forgotten {
            let e = store.debugCache.entries[r]
            check(e?.partial == true && e?.release.tagName.isEmpty == false, "\(r) version learned from the website: \(e?.release.tagName ?? "none")")
        }
        check(store.releaseErrors.values.isEmpty, "no error shown on any card (\(store.releaseErrors.count) errors)")

        // Installing a tool known only from the website while still limited explains itself.
        if let juxta = store.apps.first(where: { $0.repo == "Juxta" }) {
            await store.install(juxta)
            log("install while limited -> \(store.lastQueueFailures.first ?? "no failure")")
            check(store.lastQueueFailures.first?.contains("download limit") == true, "a clear limit message instead of a failure")
            store.alert = nil
            // Limit over: the same install fetches the downloads and works.
            unsetenv("WORKBENCH_TEST_RATELIMIT")
            store.debugClearRateLimit()
            await store.install(juxta)
            store.scanInstalled()
            check(store.installed[juxta.id]?.version == store.releases[juxta.id]?.version,
                  "after the limit resets, installing a website-only release works (installed v\(store.installed[juxta.id]?.version ?? "none"))")
        }
        log(ok ? "CACHE TESTS PASSED" : "CACHE TESTS FAILED")
        exit(ok ? 0 : 1)
    }

    /// --test-unauth: a normal user without a token. Two launches in a row, then a manual check.
    static func runUnauthTest(store: SuiteStore) async {
        let start = Date()
        func log(_ s: String) { print("[\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(s)"); fflush(stdout) }
        log("saved releases at launch: \(store.releases.count)")
        GitHub.apiRequestCount = 0
        await store.refresh(force: false)
        log("automatic check: \(GitHub.apiRequestCount) API requests; releases \(store.releases.count)/\(store.apps.count); errors \(store.releaseErrors.count); limited until \(store.rateLimitedUntil.map { "\($0)" } ?? "no")")
        let partial = store.debugCache.entries.values.filter(\.partial).count
        log("versions from the website fallback: \(partial)")
        log("updates detected: \(store.updatesAvailable.map(\.name))")
        exit(store.releases.count == store.apps.count && store.releaseErrors.isEmpty ? 0 : 1)
    }

    /// --test-permissions <dir>: checks the administrator commands (run unelevated on a scratch folder).
    static func runPermissionTest(dir: URL) {
        let fm = FileManager.default
        var ok = true
        func check(_ c: Bool, _ m: String) { ok = ok && c; print("\(c ? "PASS" : "FAIL") \(m)"); fflush(stdout) }
        func version(_ u: URL) -> String? { NSDictionary(contentsOf: u.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String }
        let old = dir.appendingPathComponent("old.app"), new = dir.appendingPathComponent("new.app")
        let folder = dir.appendingPathComponent("Apps it's \"quoted\"", isDirectory: true)   // awkward characters on purpose
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("Glint.app"), prev = folder.appendingPathComponent(".Glint.app.workbench-old")
        try? fm.removeItem(at: dest); try? fm.removeItem(at: prev)
        try? fm.copyItem(at: old, to: dest)
        let v0 = version(dest), vNew = version(new)
        do {
            try Permission.replaceAsAdmin(source: new, destination: dest, previous: prev, appName: "Glint", folder: folder)
            check(version(dest) == vNew, "admin replace puts the new version in place (\(v0 ?? "?") -> \(version(dest) ?? "?"))")
            check(!fm.fileExists(atPath: prev.path), "admin replace removes the old copy")
            let owner = (try? fm.attributesOfItem(atPath: dest.path)[.ownerAccountID] as? Int) ?? -1
            check(owner == Int(getuid()), "the new copy is handed back to the user (owner \(owner))")
        } catch { check(false, "admin replace threw \(error)") }
        // Rollback: the source is missing, so the old app must come back untouched.
        let before = version(dest)
        do {
            try Permission.replaceAsAdmin(source: dir.appendingPathComponent("missing.app"), destination: dest, previous: prev, appName: "Glint", folder: folder)
            check(false, "admin replace with a missing source should fail")
        } catch {
            check(version(dest) == before && !fm.fileExists(atPath: prev.path), "a failed admin replace restores the old app (\(version(dest) ?? "missing"))")
        }
        // The AppleScript used for the real password dialog must compile (checked by osacompile).
        let script = Permission.debugReplaceAppleScript(source: new, destination: dest, previous: prev)
        try? script.write(to: dir.appendingPathComponent("admin.applescript"), atomically: true, encoding: .utf8)
        print(ok ? "PERMISSION TESTS PASSED" : "PERMISSION TESTS FAILED")
        exit(ok ? 0 : 1)
    }

    static func runUpdateAll(store: SuiteStore) async {
        func log(_ s: String) { print("[\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(s)"); fflush(stdout) }
        let start = Date()
        await store.refresh()
        let queued = store.updatesAvailable.map(\.name)
        log("installed: \(store.installed.mapValues(\.version)), releases: \(store.releases.count), errors: \(Set(store.releaseErrors.values)), refreshing: \(store.isRefreshing)")
        log("updates available: \(queued)")
        guard !queued.isEmpty else { log("FAIL nothing to update"); exit(2) }
        // Watch state changes while Update All runs.
        var last: [String: String] = [:]
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                for app in store.apps where queued.contains(app.name) {
                    let s = "\(store.state(of: app))"
                    if last[app.name] != s { last[app.name] = s; log("\(app.name): \(s)") }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if CommandLine.arguments.contains("--press-button") {
            // Press the real on-screen "Update N Tools" button through the accessibility tree.
            try? await Task.sleep(for: .seconds(3))
            let pressed = pressButton(prefix: "Update ")
            log("pressed button: \(pressed ?? "NOT FOUND (AX: \(AXIsProcessTrusted()))")")
            if pressed == nil { exit(3) }
            try? await Task.sleep(for: .milliseconds(300))
            let snapshot = store.apps.filter { queued.contains($0.name) }.map { "\($0.name)=\(store.state(of: $0))" }
            let allInQueue = store.apps.filter { queued.contains($0.name) }.allSatisfy {
                switch store.state(of: $0) { case .working, .queued: return true; default: return false }
            }
            log("\(allInQueue ? "PASS" : "FAIL") every tool joined the queue right after pressing: \(snapshot)")
            log("queue status: \(String(describing: store.queueRun))")
            if let i = CommandLine.arguments.firstIndex(of: "--shot"), CommandLine.arguments.indices.contains(i + 1),
               let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Workbench" }) {
                await GlassSnapshot.capture(w, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                log("saved screenshot")
            }
            if !allInQueue { exit(4) }
            var removed: String?
            if CommandLine.arguments.contains("--dequeue-last"), let lastName = queued.last,
               let last = store.apps.first(where: { $0.name == lastName }) {
                store.dequeue(last); removed = lastName
                log("removed \(lastName) from the queue -> \(store.state(of: last)), queue status \(String(describing: store.queueRun))")
            }
            // Pressing again while it runs must not duplicate anything.
            if removed == nil { await store.updateAll() }
            // Wait until nothing is working and every queued app has settled.
            var idle = 0
            while idle < 30 {
                try? await Task.sleep(for: .milliseconds(200))
                let busy = store.isQueueRunning
                idle = busy ? 0 : idle + 1
            }
        } else {
            let tap = Task { @MainActor in await store.updateAll() }   // exactly what the button does
            await tap.value
            try? await Task.sleep(for: .milliseconds(500))
        }
        watcher.cancel()
        store.scanInstalled()
        var ok = true
        for app in store.apps where queued.contains(app.name) {
            let v = store.installed[app.id]?.version ?? "missing"
            let latest = store.releases[app.id]?.version ?? "?"
            let pass = v == latest
            ok = ok && pass
            log("\(pass ? "PASS" : "FAIL") \(app.name): installed v\(v), latest v\(latest)")
        }
        if let a = store.alert { log("alert: \(a)  [App Management button: \(store.needsAppManagement)]") }
        if !store.lastQueueFailures.isEmpty { log("reported failures: \(store.lastQueueFailures)") }
        let sheets = NSApp.windows.compactMap { $0.attachedSheet ?? ($0.isSheet ? $0 : nil) }
        let alertTexts = sheets.flatMap { w in w.contentView.map { allText(in: $0) } ?? [] }
        log("alert on screen: \(sheets.isEmpty ? "none" : alertTexts.joined(separator: " | "))")
        log(ok ? "ALL UPDATED" : "SOME NOT UPDATED")
        exit(ok ? 0 : 1)
    }

    static func allText(in view: NSView) -> [String] {
        var out: [String] = []
        if let t = view as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
        for v in view.subviews { out += allText(in: v) }
        return out
    }

    /// Finds and presses the first button whose title starts with `prefix` in this app's own windows.
    static func pressButton(prefix: String) -> String? {
        let app = AXUIElementCreateApplication(getpid())
        func walk(_ e: AXUIElement, depth: Int) -> String? {
            if depth > 40 { return nil }
            var role: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            var title: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &title)
            var desc: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &desc)
            let name = (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (desc as? String) ?? ""
            if (role as? String) == kAXButtonRole as String, name.hasPrefix(prefix), name != "Update" {
                AXUIElementPerformAction(e, kAXPressAction as CFString); return name
            }
            var kids: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
            for k in (kids as? [AXUIElement]) ?? [] { if let r = walk(k, depth: depth + 1) { return r } }
            return nil
        }
        return walk(app, depth: 0)
    }
}
#endif
