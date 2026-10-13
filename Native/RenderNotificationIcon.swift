import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let unit = CGFloat(pixels) / 1024
        NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64*unit, y: 64*unit, width: 896*unit, height: 896*unit),
                     xRadius: 200*unit, yRadius: 200*unit).fill()
        let phone = NSBezierPath(roundedRect: NSRect(x: 295*unit, y: 160*unit, width: 434*unit, height: 704*unit),
                                 xRadius: 86*unit, yRadius: 86*unit)
        NSColor(calibratedRed: 0.71, green: 0.96, blue: 0.79, alpha: 1).setStroke()
        phone.lineWidth = 44*unit; phone.stroke()
        NSColor(calibratedRed: 0.71, green: 0.96, blue: 0.79, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 420*unit, y: 205*unit, width: 184*unit, height: 24*unit),
                     xRadius: 12*unit, yRadius: 12*unit).fill()
        NSBezierPath(ovalIn: NSRect(x: 492*unit, y: 786*unit, width: 40*unit, height: 40*unit)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to:
            directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
