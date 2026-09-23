import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let face = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.27, blue: 0.18, alpha: 1), ending: NSColor(calibratedRed: 0.055, green: 0.070, blue: 0.065, alpha: 1))!.draw(in: face, angle: -90)
    NSColor(calibratedRed: 0.42, green: 0.51, blue: 0.31, alpha: 1).setStroke(); face.lineWidth = 5; face.stroke()
    let acid = NSColor(calibratedRed: 0.835, green: 1, blue: 0.275, alpha: 1)
    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: 355, y: 493)); shackle.line(to: NSPoint(x: 355, y: 625))
    shackle.curve(to: NSPoint(x: 669, y: 625), controlPoint1: NSPoint(x: 355, y: 837), controlPoint2: NSPoint(x: 669, y: 837))
    shackle.line(to: NSPoint(x: 669, y: 493)); shackle.lineWidth = 70; shackle.lineCapStyle = .round
    acid.setStroke(); shackle.stroke()
    acid.setFill(); NSBezierPath(roundedRect: NSRect(x: 274, y: 258, width: 476, height: 335), xRadius: 64, yRadius: 64).fill()
    NSColor(calibratedRed: 0.085, green: 0.115, blue: 0.075, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 474, y: 408, width: 76, height: 76)).fill()
    NSBezierPath(roundedRect: NSRect(x: 494, y: 350, width: 36, height: 86), xRadius: 16, yRadius: 16).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
