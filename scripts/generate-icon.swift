// Placeholder app icon: green squircle + white bolt, echoing the status
// chips. Replace Resources/AppIcon.icns with real art whenever — the build
// picks up whatever is there.
import AppKit

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // Apple's macOS icon grid: 824/1024 squircle, ~185pt corner at 1024.
    let inset = s * 100.0 / 1024.0
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(
        roundedRect: box,
        xRadius: s * 185.0 / 1024.0, yRadius: s * 185.0 / 1024.0
    )
    NSGradient(
        starting: NSColor(calibratedRed: 0.22, green: 0.80, blue: 0.37, alpha: 1),
        ending: NSColor(calibratedRed: 0.12, green: 0.60, blue: 0.28, alpha: 1)
    )!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .semibold)
    if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: bolt.size)
        tinted.lockFocus()
        bolt.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: bolt.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let symbolSize = tinted.size
        let origin = NSPoint(x: (s - symbolSize.width) / 2, y: (s - symbolSize.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
    (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x"),
]

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pixels, name) in variants {
    let rep = renderIcon(pixels: pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("iconset written")
