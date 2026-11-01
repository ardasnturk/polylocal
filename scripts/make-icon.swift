// Renders the Polylocal app icon and builds Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift            # writes build/AppIcon.iconset and Resources/AppIcon.icns
//   swift scripts/make-icon.swift --preview  # also writes build/AppIcon-1024.png
//
// Two overlapping speech bubbles ("A" and "文": many scripts, one place) on an indigo→teal squircle,
// drawn on the standard macOS 1024 pt grid (824 pt shape, 100 pt margin, drop shadow).

import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let buildDir = root.appendingPathComponent("build")
let iconset = buildDir.appendingPathComponent("AppIcon.iconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Speech bubble: a rounded rect plus a short tail under its bottom-left or bottom-right corner.
/// Filled as two separate shapes so overlapping parts never cancel out.
func fillBubble(_ rect: CGRect, radius: CGFloat, tailRight: Bool, in ctx: CGContext) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    // Built for a left tail, mirrored for a right one.
    let sign: CGFloat = tailRight ? -1 : 1
    let edge = tailRight ? rect.maxX : rect.minX
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: edge + sign * 50, y: rect.minY + 60))
    tail.addQuadCurve(to: CGPoint(x: edge + sign * 18, y: rect.minY - 54),
                      control: CGPoint(x: edge + sign * 56, y: rect.minY - 6))
    tail.addQuadCurve(to: CGPoint(x: edge + sign * 150, y: rect.minY + 4),
                      control: CGPoint(x: edge + sign * 90, y: rect.minY - 22))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.fillPath()
}

func roundedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
}

func drawText(_ text: String, font: CTFont, color fill: CGColor, centeredIn rect: CGRect, in ctx: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fill]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: rect.midX - bounds.midX, y: rect.midY - bounds.midY)
    CTLineDraw(line, ctx)
}

func renderIcon(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    // Squircle-ish rounded rect on the macOS grid.
    let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: shapeRect, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x3730A3))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0x4338CA), color(0x2563EB), color(0x0D9488)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 220, y: 924), end: CGPoint(x: 804, y: 100), options: [])
    // Soft top highlight.
    let highlight = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

    // Back bubble (translucent) with 文.
    let back = CGRect(x: 448, y: 470, width: 352, height: 300)
    ctx.saveGState()
    ctx.setAlpha(0.26)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)  // one alpha for rect + tail, no darker overlap
    ctx.setFillColor(color(0xFFFFFF))
    fillBubble(back, radius: 92, tailRight: true, in: ctx)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    // Centered in the part of the bubble the front bubble does not cover.
    drawText("文", font: CTFontCreateWithName("PingFangSC-Semibold" as CFString, 176, nil),
             color: color(0xFFFFFF), centeredIn: back.offsetBy(dx: 48, dy: 34), in: ctx)

    // Front bubble (white) with A.
    let front = CGRect(x: 224, y: 292, width: 372, height: 318)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x1E1B4B, 0.35))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)  // one shadow for rect + tail
    fillBubble(front, radius: 98, tailRight: false, in: ctx)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    drawText("A", font: roundedFont(size: 236, weight: .heavy), color: color(0x3730A3), centeredIn: front, in: ctx)
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(renderIcon(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(renderIcon(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if CommandLine.arguments.contains("--preview") {
    try writePNG(renderIcon(pixels: 1024), to: buildDir.appendingPathComponent("AppIcon-1024.png"))
}

let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)")
