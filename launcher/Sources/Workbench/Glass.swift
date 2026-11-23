import SwiftUI

/// Optional Liquid Glass theme (Settings › Appearance). Off by default; needs macOS 26.
enum GlassTheme {
    static let key = "glassTheme"
    static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

private struct GlassOnKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when the glass theme is turned on and the system supports it.
    var glassOn: Bool {
        get { self[GlassOnKey.self] }
        set { self[GlassOnKey.self] = newValue }
    }
}

/// Reads the stored setting and publishes `glassOn` to the views below.
struct GlassThemeRoot: ViewModifier {
    @AppStorage(GlassTheme.key) private var stored = false
    func body(content: Content) -> some View {
        content.environment(\.glassOn, stored && GlassTheme.supported)
    }
}

extension View {
    func glassThemeRoot() -> some View { modifier(GlassThemeRoot()) }

    /// Glass in `shape` when `on`; otherwise the view is returned untouched.
    @ViewBuilder
    func glassPanel<S: Shape>(_ on: Bool, in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if on {
            if #available(macOS 26, *) {
                self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
            } else { self }
        } else { self }
    }
}

/// The window background: the flat near-black, or a warm amber/coral glow under the glass theme.
struct SuiteBackground: View {
    let glass: Bool
    var body: some View {
        if glass {
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.amber.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Theme.coral.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 800)
                RadialGradient(colors: [Color(red: 0.45, green: 0.66, blue: 1.0).opacity(0.10), .clear], center: .trailing, startRadius: 0, endRadius: 600)
            }
        } else {
            Theme.background
        }
    }
}

/// `SecondaryButtonStyle`, drawn as a Liquid Glass capsule when the glass theme is on.
struct AdaptiveSecondaryButtonStyle: ButtonStyle {
    @Environment(\.glassOn) private var glassOn
    func makeBody(configuration: Configuration) -> some View {
        if glassOn {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .glassPanel(true, in: Capsule(), interactive: true)
                .opacity(configuration.isPressed ? 0.8 : 1)
        } else {
            SecondaryButtonStyle().makeBody(configuration: configuration)
        }
    }
}
