// Renders the Tokrate mark (macos/Resources/tokrate-mark.svg) into an .iconset folder.
// Usage: render_app_icon <output.iconset>
// The geometry mirrors BrandMarkGeometry in macos/Sources/TokrateApp/Views/BrandMark.swift.
import AppKit
import CoreGraphics
import Foundation

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

func hex(_ value: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

func render(pixels: Int) -> Data? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let canvas = CGFloat(pixels)
    // macOS icon grid: the tile fills 80.5% of the canvas, centred, with a soft shadow.
    let tileSize = canvas * 0.805
    let origin = (canvas - tileSize) / 2
    let scale = tileSize / 48
    // Flip to the SVG coordinate system (y down) with the tile origin at the top-left.
    context.translateBy(x: origin, y: canvas - origin)
    context.scaleBy(x: scale, y: -scale)

    let tile = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 48, height: 48), cornerWidth: 12, cornerHeight: 12, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012 / scale), blur: canvas * 0.025 / scale, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(tile)
    context.setFillColor(hex(0x0B2530))
    context.fillPath()
    context.restoreGState()

    // Arc: centre (24,26), radius 14, 240 degrees from 150 degrees (screen angles, y down).
    let arc = CGMutablePath()
    var first = true
    var degrees = 150.0
    while degrees <= 390.0 + 0.0001 {
        let radians = degrees * .pi / 180
        let point = CGPoint(x: 24 + cos(radians) * 14, y: 26 + sin(radians) * 14)
        if first { arc.move(to: point); first = false } else { arc.addLine(to: point) }
        degrees += 1
    }
    context.saveGState()
    context.addPath(arc)
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [hex(0x1E9BB5), hex(0x3CCFB4)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 10, y: 0), end: CGPoint(x: 38, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    context.setStrokeColor(hex(0xFF6B4A))
    context.setLineWidth(3.5)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 24, y: 26))
    context.addLine(to: CGPoint(x: 31.1, y: 18.9))
    context.strokePath()
    context.setFillColor(hex(0xFF6B4A))
    context.fillEllipse(in: CGRect(x: 24 - 2.8, y: 26 - 2.8, width: 5.6, height: 5.6))

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render_app_icon <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for item in sizes {
    guard let data = render(pixels: item.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(item.name)\n".utf8))
        exit(1)
    }
    try data.write(to: output.appendingPathComponent("\(item.name).png"))
}
