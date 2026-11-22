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
                .task { if store.checkOnLaunch { await store.refresh() } }
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
            SettingsView().environmentObject(store).preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Developer aid: `Workbench --snapshot out.png` saves an image of the main window after it loads.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
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
