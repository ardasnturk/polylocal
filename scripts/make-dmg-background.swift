// Renders the DMG window background (Resources/dmg-background.png and @2x).
//
//   swift scripts/make-dmg-background.swift
//
// Layout matches scripts/dmg-settings.py: a 660×400 pt window, the app icon centered at (170, 200)
// and the Applications link at (490, 200), in Finder coordinates (origin top-left).

import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = CGSize(width: 660, height: 400)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func font(size: CGFloat, weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return (NSFont(descriptor: descriptor, size: size) ?? base) as CTFont
}

/// Draws `text` horizontally centered on `x`, with its baseline at `y` (bottom-left coordinates).
func drawText(_ text: String, font: CTFont, color fill: CGColor, centerX x: CGFloat, baseline y: CGFloat, in ctx: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fill]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: x - width / 2, y: y)
    CTLineDraw(line, ctx)
}

func render(scale: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)

    // Light wash of the icon's indigo → teal, so Finder's dark label text stays readable.
    let wash = CGGradient(colorsSpace: space, colors: [color(0xEEF0FF), color(0xF4F8FF), color(0xE8F7F4)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(wash, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])

    // Soft halos behind the two icon slots (y = 400 - 200 in bottom-left coordinates).
    for x in [170.0, 490.0] {
        let halo = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.9), color(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(halo, startCenter: CGPoint(x: x, y: 205), startRadius: 0,
                               endCenter: CGPoint(x: x, y: 205), endRadius: 110, options: [])
    }

    // Arrow from the app to Applications.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 262, y: 208))
    arrow.addQuadCurve(to: CGPoint(x: 388, y: 208), control: CGPoint(x: 325, y: 238))
    ctx.setStrokeColor(color(0x4338CA, 0.55))
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1, 13])
    ctx.addPath(arrow)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 376, y: 224))
    head.addLine(to: CGPoint(x: 394, y: 207))
    head.addLine(to: CGPoint(x: 372, y: 198))
    ctx.setLineWidth(5)
    ctx.setLineJoin(.round)
    ctx.addPath(head)
    ctx.strokePath()

    drawText("Drag Polylocal to Applications", font: font(size: 22, weight: .semibold), color: color(0x1E1B4B),
             centerX: size.width / 2, baseline: 330, in: ctx)
    drawText("Local, private translation for your Mac", font: font(size: 13, weight: .regular),
             color: color(0x1E1B4B, 0.55), centerX: size.width / 2, baseline: 306, in: ctx)
    drawText("Then open Polylocal from Applications. The setup assistant guides you through the rest.",
             font: font(size: 12, weight: .regular), color: color(0x1E1B4B, 0.5),
             centerX: size.width / 2, baseline: 52, in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL, dpi: CGFloat) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = size  // 72 dpi at 1x, 144 dpi at 2x: Finder picks the right one.
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let out = root.appendingPathComponent("Resources")
try writePNG(render(scale: 1), to: out.appendingPathComponent("dmg-background.png"), dpi: 72)
try writePNG(render(scale: 2), to: out.appendingPathComponent("dmg-background@2x.png"), dpi: 144)
print("Wrote \(out.path)/dmg-background{,@2x}.png")
