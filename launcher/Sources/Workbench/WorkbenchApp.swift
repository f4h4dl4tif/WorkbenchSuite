import SwiftUI

@main
struct WorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = SuiteStore()

    var body: some Scene {
        Window("Workbench", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(.dark)
                .glassThemeRoot()
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("--test-update-all") { await TestMode.runUpdateAll(store: store); return }
                    #endif
                    if store.checkOnLaunch { await store.refresh() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(store).preferredColorScheme(.dark).glassThemeRoot()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Developer aid: `Workbench --snapshot out.png` saves an image of the main window after it loads.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // Developer aid: `Workbench --test-install <repo> <folder>` installs one tool's latest release
        // into <folder> (not /Applications), prints the result and quits.
        if let i = args.firstIndex(of: "--test-install"), args.indices.contains(i + 2) {
            let repo = args[i + 1], folder = URL(fileURLWithPath: args[i + 2])
            Task {
                let catalog = Catalog.bundled()
                guard let app = catalog.apps.first(where: { $0.repo == repo }) else { print("FAIL unknown repo"); exit(2) }
                do {
                    let gh = GitHub(token: nil)
                    let release = try await gh.latestRelease(owner: catalog.owner, repo: repo)
                    guard let asset = release.installAsset else { print("FAIL no asset"); exit(3) }
                    print("release v\(release.version) asset \(asset.name)")
                    let outcome = try await Installer.install(app: app, asset: asset, github: gh, location: folder) { _ in }
                    print("OK \(outcome)")
                    exit(0)
                } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        #if DEBUG
        if let i = args.firstIndex(of: "--glass-snapshot"), args.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in await GlassSnapshot.run(dir) }
            return
        }
        #endif
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return }
        let path = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if args.contains("--quit") { NSApp.terminate(nil) }
        }
    }
}
