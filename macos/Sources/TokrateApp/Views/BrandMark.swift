import AppKit
import SwiftUI

/// Geometry of the Tokrate mark in its 48-unit design space (`macos/Resources/tokrate-mark.svg`).
/// `macos/script/render_app_icon.swift` draws the same geometry for the app icon.
enum BrandMarkGeometry {
    static let canvas = 48.0
    static let tileRadius = 12.0
    static let arcCenter = CGPoint(x: 24, y: 26)
    static let arcRadius = 14.0
    static let arcStartDegrees = 150.0
    static let arcSweepDegrees = 240.0
    static let arcWidth = 4.0
    static let needleEnd = CGPoint(x: 31.1, y: 18.9)
    static let needleWidth = 3.5
    static let hubRadius = 2.8

    /// Points along the arc (screen angles, y pointing down).
    static func arcPoints(step: Double = 2) -> [CGPoint] {
        stride(from: 0.0, through: arcSweepDegrees, by: step).map { offset in
            let radians = (arcStartDegrees + offset) * .pi / 180
            return CGPoint(x: arcCenter.x + cos(radians) * arcRadius, y: arcCenter.y + sin(radians) * arcRadius)
        }
    }
}

/// The ink tile with the cyan-to-teal arc and the needle.
struct BrandMarkView: View {
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / BrandMarkGeometry.canvas
            func point(_ source: CGPoint) -> CGPoint { CGPoint(x: source.x * scale, y: source.y * scale) }
            let tile = RoundedRectangle(cornerRadius: BrandMarkGeometry.tileRadius * scale, style: .continuous)
                .path(in: CGRect(origin: .zero, size: canvasSize))
            context.fill(tile, with: .color(DashboardStyle.brandInk))
            // A faint edge keeps the ink tile readable on dark surfaces.
            context.stroke(tile, with: .color(.white.opacity(0.14)), lineWidth: max(0.5, scale * 0.5))

            var arc = Path()
            arc.addArc(
                center: point(BrandMarkGeometry.arcCenter),
                radius: BrandMarkGeometry.arcRadius * scale,
                startAngle: .degrees(BrandMarkGeometry.arcStartDegrees),
                endAngle: .degrees(BrandMarkGeometry.arcStartDegrees + BrandMarkGeometry.arcSweepDegrees),
                clockwise: false
            )
            let left = point(CGPoint(x: BrandMarkGeometry.arcCenter.x - BrandMarkGeometry.arcRadius, y: 26))
            let right = point(CGPoint(x: BrandMarkGeometry.arcCenter.x + BrandMarkGeometry.arcRadius, y: 26))
            context.stroke(
                arc,
                with: .linearGradient(Gradient(colors: [DashboardStyle.arcStart, DashboardStyle.arcEnd]), startPoint: left, endPoint: right),
                style: StrokeStyle(lineWidth: BrandMarkGeometry.arcWidth * scale, lineCap: .round)
            )

            var needle = Path()
            needle.move(to: point(BrandMarkGeometry.arcCenter))
            needle.addLine(to: point(BrandMarkGeometry.needleEnd))
            context.stroke(needle, with: .color(DashboardStyle.brandNeedle), style: StrokeStyle(lineWidth: BrandMarkGeometry.needleWidth * scale, lineCap: .round))
            let hub = point(BrandMarkGeometry.arcCenter)
            let hubRadius = BrandMarkGeometry.hubRadius * scale
            context.fill(Path(ellipseIn: CGRect(x: hub.x - hubRadius, y: hub.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)), with: .color(DashboardStyle.brandNeedle))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The monochrome menu-bar glyph: the same arc and needle, drawn as a template image so the
/// system tints it for light, dark and highlighted menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            // The arc and needle occupy roughly x 9...39, y 8...37 of the mark; fit them to the glyph.
            let scale: CGFloat = 0.62
            let origin = CGPoint(x: 24, y: 22.5)
            func point(_ source: CGPoint) -> CGPoint {
                CGPoint(x: side / 2 + (source.x - origin.x) * scale, y: side / 2 + (source.y - origin.y) * scale)
            }
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let arc = NSBezierPath()
            for (index, source) in BrandMarkGeometry.arcPoints(step: 1).enumerated() {
                index == 0 ? arc.move(to: point(source)) : arc.line(to: point(source))
            }
            arc.lineWidth = BrandMarkGeometry.arcWidth * scale
            arc.lineCapStyle = .round
            arc.lineJoinStyle = .round
            arc.stroke()
            let needle = NSBezierPath()
            needle.move(to: point(BrandMarkGeometry.arcCenter))
            needle.line(to: point(BrandMarkGeometry.needleEnd))
            needle.lineWidth = BrandMarkGeometry.needleWidth * scale
            needle.lineCapStyle = .round
            needle.stroke()
            let hub = point(BrandMarkGeometry.arcCenter)
            let radius = BrandMarkGeometry.hubRadius * scale
            NSBezierPath(ovalIn: NSRect(x: hub.x - radius, y: hub.y - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tokrate"
        return image
    }()
}
