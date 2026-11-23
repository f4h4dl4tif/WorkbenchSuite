#if DEBUG
import AppKit

/// Developer aid (DEBUG builds only).
///   WORKBENCH_TEST_ROOT=<dir>   look for and install tools only in <dir>, never /Applications.
///   --test-update-all           refresh, press "Update All" (the same store call the buttons make),
///                               log every state change, print a summary and quit.
@MainActor
enum TestMode {
    nonisolated static let root: URL? = ProcessInfo.processInfo.environment["WORKBENCH_TEST_ROOT"].map { URL(fileURLWithPath: $0) }

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
        if let a = store.alert { log("alert: \(a)") }
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
