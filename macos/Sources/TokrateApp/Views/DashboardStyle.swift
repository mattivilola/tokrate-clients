import AppKit
import SwiftUI

extension Color {
    /// An sRGB color from a 0xRRGGBB value.
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A color that follows the effective appearance (window or explicit `preferredColorScheme`).
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The Tokrate design tokens from `docs/design-language.md`. Views never use raw system hues.
enum DashboardStyle {
    // MARK: Surfaces and text
    static let bg = Color(light: 0xF4F7F8, dark: 0x0A1A20)
    static let surface = Color(light: 0xFFFFFF, dark: 0x10252D)
    static let surface2 = Color(light: 0xEEF3F5, dark: 0x16303A)
    static let line = Color(light: 0xDCE5E9, dark: 0x23414C)
    static let ink = Color(light: 0x0B2530, dark: 0xE8F1F3)
    static let muted = Color(light: 0x5B6F78, dark: 0x9DB3BB)

    // MARK: Accent and status
    static let accent = Color(light: 0x0F7C86, dark: 0x4FD1C5)
    static let accentStrong = Color(light: 0x0A5F68, dark: 0x7FE3D8)
    /// Text on a filled accent background.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x062026)
    static let warn = Color(light: 0xB7791F, dark: 0xF2B24C)
    static let good = Color(light: 0x2E8F62, dark: 0x5BC98F)
    static let danger = Color(light: 0xC8423B, dark: 0xF07A72)

    // MARK: Gauge and charts
    static let arcStart = Color(hex: 0x1E9BB5)
    static let arcEnd = Color(hex: 0x3CCFB4)
    /// Gauge needle and hub only; never an error color.
    static let needle = Color(light: 0xE4572E, dark: 0xFF7A55)
    static let gradient = LinearGradient(colors: [arcStart, arcEnd], startPoint: .leading, endPoint: .trailing)

    // MARK: Brand tile
    static let brandInk = Color(hex: 0x0B2530)
    static let brandNeedle = Color(hex: 0xFF6B4A)

    // MARK: Shape
    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let chip: CGFloat = 8
    }

    // MARK: Typography (Mac minimum 11 pt; large readouts use the rounded design)
    enum Typography {
        static let caption = Font.system(size: 11)
        static let captionEmphasis = Font.system(size: 11, weight: .semibold)
        static let footnote = Font.system(size: 12)
        static let footnoteEmphasis = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyEmphasis = Font.system(size: 13, weight: .semibold)
        static let title = Font.system(size: 15, weight: .semibold)
        static let largeTitle = Font.system(size: 22, weight: .semibold)
        static func readout(size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .rounded) }
        static func value(size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    }
}

// MARK: - Cards and chrome

struct DashboardCard: ViewModifier {
    var padding: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DashboardStyle.surface, in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.Radius.card, style: .continuous)
                    .strokeBorder(DashboardStyle.line, lineWidth: 1)
            }
            // Dark mode uses the border only.
            .shadow(color: colorScheme == .dark ? .clear : Color(hex: 0x0B2530).opacity(0.06), radius: 12, y: 4)
            .shadow(color: colorScheme == .dark ? .clear : Color(hex: 0x0B2530).opacity(0.05), radius: 1, y: 1)
    }
}

extension View {
    func dashboardCard(padding: CGFloat = 16) -> some View { modifier(DashboardCard(padding: padding)) }

    /// A flat inset on the card background, used for controls tracks and grouped details.
    func dashboardInset(padding: CGFloat = 12, radius: CGFloat = DashboardStyle.Radius.control) -> some View {
        self.padding(padding)
            .background(DashboardStyle.surface2, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Filled accent button (primary action). Radius 10, never a pill.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DashboardStyle.Typography.bodyEmphasis)
            .foregroundStyle(DashboardStyle.onAccent)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(configuration.isPressed ? DashboardStyle.accentStrong : DashboardStyle.accent,
                        in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Quiet bordered button on the surface-2 inset color.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DashboardStyle.Typography.body)
            .foregroundStyle(DashboardStyle.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(configuration.isPressed ? DashboardStyle.line : DashboardStyle.surface2,
                        in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous)
                    .strokeBorder(DashboardStyle.line, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Both consent choices share this one style so neither answer is visually favoured.
struct ConsentChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DashboardStyle.Typography.bodyEmphasis)
            .foregroundStyle(DashboardStyle.accentStrong)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? DashboardStyle.surface2 : DashboardStyle.surface,
                        in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardStyle.Radius.control, style: .continuous)
                    .strokeBorder(DashboardStyle.accent, lineWidth: 1.5)
            }
    }
}

/// A small status chip: effort, subagent, early data.
struct ChipView: View {
    enum Tone { case neutral, accent, warn, good }
    let text: String
    var tone: Tone = .neutral

    private var color: Color {
        switch tone {
        case .neutral: DashboardStyle.muted
        case .accent: DashboardStyle.accentStrong
        case .warn: DashboardStyle.warn
        case .good: DashboardStyle.good
        }
    }

    var body: some View {
        Text(text)
            .font(DashboardStyle.Typography.captionEmphasis)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: DashboardStyle.Radius.chip, style: .continuous))
    }
}

/// Section label used in lists and settings.
struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(DashboardStyle.Typography.footnoteEmphasis)
            .foregroundStyle(DashboardStyle.muted)
            .accessibilityAddTraits(.isHeader)
    }
}
