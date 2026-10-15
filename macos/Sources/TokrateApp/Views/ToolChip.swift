import AppKit
import SwiftUI
import TokrateCore

/// Brand colours shared by menu icons and SwiftUI chips, matching the website and desktop client.
enum ToolChip {
    static let size = CGSize(width: 20, height: 13)
    static let cornerRadius: CGFloat = 3.5

    @MainActor private static var images: [String: NSImage] = [:]

    struct Palette: Equatable, Sendable {
        let background: UInt32
        let foreground: UInt32
    }

    static func palette(chip: String, isDark: Bool) -> Palette? {
        switch chip {
        case "CX": Palette(background: 0x10A37F, foreground: 0xFFFFFF)
        case "CC": Palette(background: 0xD97757, foreground: 0xFFFFFF)
        case "GB": Palette(background: isDark ? 0xFFFFFF : 0x000000, foreground: isDark ? 0x000000 : 0xFFFFFF)
        case "AG": Palette(background: 0x4285F4, foreground: 0xFFFFFF)
        case "OC": Palette(background: isDark ? 0x9DB3BB : 0x566770, foreground: isDark ? 0x0A1A20 : 0xFFFFFF)
        case "KC": Palette(background: 0x6C47FF, foreground: 0xFFFFFF)
        case "T3": Palette(background: 0x319CFC, foreground: 0x071B2E)
        default: nil
        }
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                green: Double((rgb >> 8) & 255) / 255,
                blue: Double(rgb & 255) / 255, alpha: 1)
    }

    /// Full-colour menu images preserve the brand instead of inheriting the menu's monochrome tint.
    @MainActor static func image(chip: String, isDark: Bool = false) -> NSImage {
        let key = "\(chip)|\(isDark)"
        if let cached = images[key] { return cached }
        let palette = palette(chip: chip, isDark: isDark)
        let image = NSImage(size: size, flipped: false) { rect in
            let accent = palette.map { color($0.background) }
            let ink = palette.map { color($0.foreground) } ?? NSColor.labelColor
            (accent ?? NSColor.labelColor).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            outline.lineWidth = 1
            if let accent { accent.setFill(); outline.fill() }
            outline.stroke()
            let text = NSAttributedString(string: chip, attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: ink
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = palette == nil
        image.accessibilityDescription = CodingTool.known.first { $0.chip == chip }?.title
        images[key] = image
        return image
    }
}

/// The chip beside the picker button text.
struct ToolChipView: View {
    let tool: CodingTool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = ToolChip.palette(chip: tool.chip, isDark: colorScheme == .dark)
        Text(tool.chip)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(palette.map { Color(nsColor: ToolChip.color($0.foreground)) } ?? Color.secondary)
            .frame(width: ToolChip.size.width, height: ToolChip.size.height)
            .background(palette.map { Color(nsColor: ToolChip.color($0.background)) } ?? Color.clear, in: RoundedRectangle(cornerRadius: ToolChip.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ToolChip.cornerRadius, style: .continuous)
                    .strokeBorder(palette.map { Color(nsColor: ToolChip.color($0.background)) } ?? Color.secondary, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tool.title)
    }
}

struct ToolChipLabel: View {
    let title: String
    let tool: CodingTool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label { Text(title) } icon: {
            Image(nsImage: ToolChip.image(chip: tool.chip, isDark: colorScheme == .dark))
                .renderingMode(.original)
        }
    }
}
