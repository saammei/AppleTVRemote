import AppKit

// Generates the AppleTVRemote app icon: dark gradient rounded background + white av.remote symbol
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outDir = scriptDir.deletingLastPathComponent().appendingPathComponent("AppleTVRemote/Assets.xcassets/AppIcon.appiconset").path
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makeIcon(pixels: Int, to path: String) {
    let px = pixels
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let w = CGFloat(px)
    let rect = NSRect(x: 0, y: 0, width: w, height: w)
    let rounded = NSBezierPath(roundedRect: rect, xRadius: w * 0.225, yRadius: w * 0.225)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.30, green: 0.34, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 1),
    ])!
    gradient.draw(in: rounded, angle: -60)

    let base = NSImage(systemSymbolName: "av.remote", accessibilityDescription: nil)!
    let size = NSImage.SymbolConfiguration(pointSize: w * 0.56, weight: .regular)
    let white = NSImage.SymbolConfiguration(paletteColors: [.white])
    let symbol = base.withSymbolConfiguration(size.applying(white))!
    let inset = w * 0.24
    symbol.draw(in: NSRect(x: inset, y: inset, width: w - inset * 2, height: w - inset * 2))

    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

makeIcon(pixels: 16, to: outDir + "/icon_16x16.png")
makeIcon(pixels: 32, to: outDir + "/icon_16x16@2x.png")
makeIcon(pixels: 32, to: outDir + "/icon_32x32.png")
makeIcon(pixels: 64, to: outDir + "/icon_32x32@2x.png")
makeIcon(pixels: 128, to: outDir + "/icon_128x128.png")
makeIcon(pixels: 256, to: outDir + "/icon_128x128@2x.png")
makeIcon(pixels: 256, to: outDir + "/icon_256x256.png")
makeIcon(pixels: 512, to: outDir + "/icon_256x256@2x.png")
makeIcon(pixels: 512, to: outDir + "/icon_512x512.png")
makeIcon(pixels: 1024, to: outDir + "/icon_512x512@2x.png")
print("done")
