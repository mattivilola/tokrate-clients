import AppKit
import SwiftUI

/// The coding-tool chip: two letters in a stroked rounded rectangle. Neutral on purpose; the
/// maker badge next to it carries the colour.
enum ToolChip {
    static let size = CGSize(width: 20, height: 13)
    static let cornerRadius: CGFloat = 3.5

    @MainActor private static var images: [String: NSImage] = [:]

    /// The chip as a menu-item icon: a template image, so the menu tints it for light, dark and
    /// highlighted rows. Drawn in the label colour, which the handler resolves for the appearance it
    /// draws in, so it stays legible where a host draws it untinted. Cached per chip text.
    @MainActor static func image(chip: String) -> NSImage {
        if let cached = images[chip] { return cached }
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            outline.lineWidth = 1
            outline.stroke()
            let text = NSAttributedString(string: chip, attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
        image.isTemplate = true
        images[chip] = image
        return image
    }
}

/// The chip beside the picker button text.
struct ToolChipView: View {
    let tool: CodingTool

    var body: some View {
        Text(tool.chip)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: ToolChip.size.width, height: ToolChip.size.height)
            .overlay {
                RoundedRectangle(cornerRadius: ToolChip.cornerRadius, style: .continuous)
                    .strokeBorder(.secondary, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tool.title)
    }
}
