import SwiftUI

enum Theme {
    static let background = Color(red: 0.051, green: 0.055, blue: 0.071)      // #0D0E12
    static let card = Color(red: 0.086, green: 0.094, blue: 0.118)            // #16181E
    static let cardHover = Color(red: 0.110, green: 0.118, blue: 0.145)
    static let border = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let amber = Color(red: 1.0, green: 0.71, blue: 0.28)              // #FFB547
    static let coral = Color(red: 1.0, green: 0.38, blue: 0.36)              // #FF615C
    static let accent = LinearGradient(colors: [amber, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let mint = Color(red: 0.42, green: 0.89, blue: 0.66)

    static func categoryColor(_ category: String) -> Color {
        switch category {
        case "System": return Color(red: 0.45, green: 0.66, blue: 1.0)
        case "Productivity": return mint
        case "Files & Code": return Color(red: 0.75, green: 0.55, blue: 1.0)
        default: return amber
        }
    }

    static func categoryIcon(_ category: String) -> String {
        switch category {
        case "System": return "cpu"
        case "Productivity": return "checklist"
        case "Files & Code": return "chevron.left.forwardslash.chevron.right"
        default: return "leaf"
        }
    }
}

/// Small rounded label, used for categories and status.
struct Pill: View {
    let text: String
    var color: Color = Theme.secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// "01 / THE LINEUP" style section label.
struct SectionLabel: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(number).foregroundStyle(Theme.amber)
            Text("/").foregroundStyle(Theme.tertiary)
            Text(title.uppercased()).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .tracking(1.2)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: Capsule())
            .overlay(Capsule().stroke(Theme.border))
    }
}
