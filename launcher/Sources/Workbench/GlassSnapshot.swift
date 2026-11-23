#if DEBUG
import AppKit
import SwiftUI

extension Notification.Name {
    /// Debug-only: asks the main view to show (object = app id) or hide (nil) a tool's detail sheet.
    static let glassSnapshotDetail = Notification.Name("WorkbenchGlassSnapshotDetail")
}

/// Developer aid (debug builds only): `Workbench --glass-snapshot <dir>` captures the main window, a tool's
/// detail sheet and Settings with the Liquid Glass theme off and on (the app is always dark), using the app's own
/// window capture (renders real glass), then restores the saved setting and quits.
@MainActor
enum GlassSnapshot {
    static func run(_ dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: GlassTheme.key)
        try? await Task.sleep(for: .seconds(6))   // let the catalog and release checks settle
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { NSApp.terminate(nil); return }

        for glass in [false, true] {
            defaults.set(glass, forKey: GlassTheme.key)
            let suffix = "\(glass ? "glass" : "plain")-dark"
            try? await Task.sleep(for: .seconds(1.2))
            await capture(window, to: dir.appendingPathComponent("main-\(suffix).png"))

            NotificationCenter.default.post(name: .glassSnapshotDetail, object: "first")
            try? await Task.sleep(for: .seconds(1.5))
            if let sheet = window.attachedSheet ?? window.sheets.first {
                await capture(sheet, to: dir.appendingPathComponent("detail-\(suffix).png"), activate: false)
            }
            NotificationCenter.default.post(name: .glassSnapshotDetail, object: nil)
            try? await Task.sleep(for: .seconds(1))

            NSApp.activate(ignoringOtherApps: true)
            if let appMenu = NSApp.mainMenu?.items.first?.submenu,
               let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                appMenu.performActionForItem(at: i)
            }
            try? await Task.sleep(for: .seconds(1.2))
            if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.frame.width > 300 }) {
                await capture(settings, to: dir.appendingPathComponent("settings-\(suffix).png"))
                settings.close()
            }
        }
        if let original { defaults.set(original, forKey: GlassTheme.key) } else { defaults.removeObject(forKey: GlassTheme.key) }
        NSApp.terminate(nil)
    }

    private typealias CapFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func capture(_ window: NSWindow, to url: URL, activate: Bool = true) async {
        if activate {
            for _ in 0..<30 where !(NSApp.isActive && window.isKeyWindow) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let f = unsafeBitCast(sym, to: CapFn.self)
        guard let img = f(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
