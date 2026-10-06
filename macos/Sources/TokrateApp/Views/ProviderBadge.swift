import AppKit
import SwiftUI

/// Badge colours by model maker. Letters only, never company logos. xAI flips with the appearance:
/// a black disc with a white X on light surfaces, a white disc with a black X on dark ones.
enum ProviderBadgePalette {
    static let anthropic: UInt32 = 0xD97757
    static let openAI: UInt32 = 0x10A37F
    static let google: UInt32 = 0x4285F4
    static let neutral: UInt32 = 0x8A9AA1

    static func fill(_ maker: ModelMaker, isDark: Bool) -> UInt32 {
        switch maker {
        case .anthropic: anthropic
        case .openAI: openAI
        case .xAI: isDark ? 0xFFFFFF : 0x000000
        case .google: google
        case .unknown: neutral
        }
    }

    static func letterColor(_ maker: ModelMaker, isDark: Bool) -> UInt32 {
        maker == .xAI && isDark ? 0x000000 : 0xFFFFFF
    }
}

/// The badge in the popover header and hero.
struct ProviderBadgeView: View {
    let maker: ModelMaker
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Circle()
            .fill(Color(hex: ProviderBadgePalette.fill(maker, isDark: isDark)))
            .frame(width: size, height: size)
            .overlay {
                if let letter = maker.letter {
                    Text(letter)
                        .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: ProviderBadgePalette.letterColor(maker, isDark: isDark)))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(maker.title)
    }
}

/// The badge as a menu-bar image: drawn crisp at any backing scale, never a template (it has to keep
/// its colour). The gauge glyph stays a template when the badge is hidden.
enum MenuBarBadge {
    static let side: CGFloat = 15

    static func image(for maker: ModelMaker, isDarkMenuBar: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let disc = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor(hex: ProviderBadgePalette.fill(maker, isDark: isDarkMenuBar)).setFill()
            NSBezierPath(ovalIn: disc).fill()
            guard let letter = maker.letter else { return true }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor(hex: ProviderBadgePalette.letterColor(maker, isDark: isDarkMenuBar))
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = maker.title
        return image
    }
}

/// The menu-bar item: the provider badge (or the gauge glyph) and the live response speed.
struct MenuBarLabel: View {
    let readout: MenuBarReadout
    let showsSpeed: Bool
    let showsBadge: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            if showsSpeed, showsBadge, let maker = readout.maker {
                Image(nsImage: MenuBarBadge.image(for: maker, isDarkMenuBar: colorScheme == .dark))
                    .renderingMode(.original)
            } else {
                Image(nsImage: MenuBarIcon.image)
            }
            if showsSpeed {
                Text(readout.speedText).monospacedDigit()
            }
        }
        .accessibilityLabel(showsSpeed ? readout.accessibilityLabel : "Tokrate")
    }
}
