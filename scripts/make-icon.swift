// Renders Support/AppIcon.icns: a rounded square with a gradient and a speech-to-text glyph.
import AppKit

func render(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.23, yRadius: rect.width * 0.23)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.36, blue: 0.40, alpha: 1), NSColor(red: 0.47, green: 0.33, blue: 0.98, alpha: 1)])!
        .draw(in: path, angle: -60)
    // Waveform bars flowing into text lines.
    NSColor.white.setFill()
    let heights: [CGFloat] = [0.16, 0.34, 0.52, 0.30, 0.44]
    let barWidth = rect.width * 0.06
    let gap = rect.width * 0.04
    var x = rect.minX + rect.width * 0.15
    for h in heights {
        let height = rect.height * h
        NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height), xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    let lineX = x + gap * 0.6
    let lineHeight = rect.height * 0.07
    for (i, w) in [0.19, 0.14, 0.17].enumerated() {
        let y = rect.midY + rect.height * 0.14 - CGFloat(i) * rect.height * 0.14 - lineHeight / 2
        NSBezierPath(roundedRect: NSRect(x: lineX, y: y, width: rect.width * w, height: lineHeight), xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
