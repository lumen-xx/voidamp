import AppKit
// Puts screenshots on Voidamp's night-sky background with a headline, for the README and announcements.
// Usage: swift scripts/marketing.swift <out.png> <headline> <subtitle> <icon.png> <image.png>...
// Several images are placed side by side, centred on each other.
let arguments = CommandLine.arguments
let output = URL(fileURLWithPath: arguments[1])
let headline = arguments[2], subtitle = arguments[3]
let icon = NSImage(contentsOf: URL(fileURLWithPath: arguments[4]))
let images = arguments.dropFirst(5).map { NSImage(contentsOf: URL(fileURLWithPath: $0))! }

func pixelSize(_ image: NSImage) -> NSSize {
    image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
}
let sizes = images.map(pixelSize)
let gap: CGFloat = 70
let contentWidth = sizes.map(\.width).reduce(0, +) + gap * CGFloat(max(0, sizes.count - 1))
let contentHeight = sizes.map(\.height).max() ?? 0
let width = max(1600, contentWidth + 240), top: CGFloat = 230
let height = top + contentHeight + 50
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: width, height: height)
// The icon's night sky: deep navy into near-black, a soft blue glow where the screenshots sit, and faint stars.
NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.36, alpha: 1), NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.07, alpha: 1)])!
    .draw(in: canvas, angle: -70)
NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.55, blue: 1, alpha: 0.18), .clear])!
    .draw(fromCenter: NSPoint(x: width / 2, y: height * 0.42), radius: 0, toCenter: NSPoint(x: width / 2, y: height * 0.42), radius: width * 0.55, options: [])
var seed: UInt64 = 7
func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31) }
for _ in 0..<Int(width * height / 2600) {
    let size = 0.6 + next() * 1.6
    NSColor.white.withAlphaComponent(0.15 + next() * 0.55).setFill()
    NSBezierPath(ovalIn: NSRect(x: next() * width, y: next() * height, width: size, height: size)).fill()
}

let center = NSMutableParagraphStyle()
center.alignment = .center
let title = NSAttributedString(string: headline, attributes: [.font: NSFont.systemFont(ofSize: 54, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: center])
let titleSize = title.size()
let iconSide: CGFloat = 64, iconGap: CGFloat = 18
let lineWidth = titleSize.width + (icon == nil ? 0 : iconSide + iconGap)
let lineX = (width - lineWidth) / 2, titleY = height - 70 - titleSize.height
icon?.draw(in: NSRect(x: lineX, y: titleY + (titleSize.height - iconSide) / 2 - 2, width: iconSide, height: iconSide))
title.draw(at: NSPoint(x: lineX + (icon == nil ? 0 : iconSide + iconGap), y: titleY))
let sub = NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .regular),
                                                             .foregroundColor: NSColor.white.withAlphaComponent(0.72), .paragraphStyle: center])
sub.draw(in: NSRect(x: 60, y: titleY - 52, width: width - 120, height: 40))

// The screenshots at their own size, so they stay sharp.
var x = (width - contentWidth) / 2
for (image, size) in zip(images, sizes) {
    image.draw(in: NSRect(x: x, y: 40 + (contentHeight - size.height) / 2, width: size.width, height: size.height))
    x += size.width + gap
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("Wrote \(output.path) (\(Int(width))×\(Int(height)))")
