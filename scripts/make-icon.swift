// Draws the TypeMouse app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
//
// The design is original artwork. SF Symbols may not be used in app icons.
import AppKit

let canvas: CGFloat = 1024

func drawIcon(in ctx: CGContext) {
    // Coordinates below use a top-left origin, like the design grid.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: an 824 pt body with a continuous-corner rounded rectangle.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bodyPath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.95, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    ctx.restoreGState()

    // Cursor arrow. The tip sits up and left of center.
    let tip = CGPoint(x: 400, y: 330)
    let s: CGFloat = 520
    let points: [CGPoint] = [
        (0, 0), (0, 0.80), (0.19, 0.62), (0.32, 0.92), (0.45, 0.86), (0.32, 0.57), (0.57, 0.57),
    ].map { CGPoint(x: tip.x + $0.0 * s, y: tip.y + $0.1 * s) }
    let arrow = CGMutablePath()
    arrow.addLines(between: points)
    arrow.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 20, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.addPath(arrow)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(22)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
    ctx.strokePath()

    // Rays from the tip: up, up-left, left.
    ctx.setLineCap(.round)
    ctx.setLineWidth(34)
    ctx.setStrokeColor(NSColor.white.cgColor)
    for degrees in [90.0, 135.0, 180.0] {
        let a = degrees * .pi / 180
        let inner: CGFloat = 70, outer: CGFloat = 150
        ctx.move(to: CGPoint(x: tip.x + cos(a) * inner, y: tip.y - sin(a) * inner))
        ctx.addLine(to: CGPoint(x: tip.x + cos(a) * outer, y: tip.y - sin(a) * outer))
    }
    ctx.strokePath()

    // A hint label, the same yellow TypeMouse draws on screen.
    let pill = CGRect(x: 560, y: 670, width: 280, height: 170)
    let pillPath = CGPath(roundedRect: pill, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.addPath(pillPath)
    ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(pillPath)
    ctx.setLineWidth(6)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
    ctx.strokePath()

    // Text draws in flipped space, so undo the flip around the text only.
    let text = NSAttributedString(string: "FJ", attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 128, weight: .heavy),
        .foregroundColor: NSColor.black,
    ])
    let size = text.size()
    ctx.saveGState()
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(at: CGPoint(x: pill.midX - size.width / 2, y: canvas - pill.midY - size.height / 2 + 4))
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("docs/images/icon.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
