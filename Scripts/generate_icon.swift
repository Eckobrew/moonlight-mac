import AppKit
import CoreGraphics

func createMoonlightIcon(size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(origin: .zero, size: size)

    // Draw squircle background (macOS rounded rect style)
    let cornerRadius = size.width * 0.224
    let path = CGPath(roundedRect: rect.insetBy(dx: size.width * 0.05, dy: size.height * 0.05),
                      cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius,
                      transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Background Gradient: Deep Midnight Space Blue
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1.0).cgColor,
        NSColor(red: 0.08, green: 0.12, blue: 0.24, alpha: 1.0).cgColor,
        NSColor(red: 0.12, green: 0.09, blue: 0.28, alpha: 1.0).cgColor
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.5, 1.0]
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations) {
        ctx.drawLinearGradient(bgGradient,
                               start: CGPoint(x: 0, y: size.height),
                               end: CGPoint(x: size.width, y: 0),
                               options: [])
    }

    // Outer subtle glow / rim light
    ctx.setStrokeColor(NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.35).cgColor)
    ctx.setLineWidth(size.width * 0.012)
    ctx.addPath(path)
    ctx.strokePath()

    // Draw Glowing Crescent Moon
    let moonCenter = CGPoint(x: size.width * 0.52, y: size.height * 0.52)
    let outerRadius = size.width * 0.28
    let innerRadius = size.width * 0.25
    let innerOffset = CGPoint(x: size.width * 0.09, y: size.height * 0.08)

    let moonOuterPath = CGMutablePath()
    moonOuterPath.addArc(center: moonCenter, radius: outerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)

    let moonInnerPath = CGMutablePath()
    moonInnerPath.addArc(center: CGPoint(x: moonCenter.x + innerOffset.x, y: moonCenter.y + innerOffset.y),
                         radius: innerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)

    // Subtract inner from outer
    ctx.saveGState()
    ctx.addPath(moonOuterPath)
    ctx.clip()
    ctx.addPath(moonInnerPath)
    ctx.clip(using: .evenOdd)

    // Moon gradient: Radiant cyan to electric blue
    let moonColors = [
        NSColor(red: 0.95, green: 0.98, blue: 1.00, alpha: 1.0).cgColor,
        NSColor(red: 0.38, green: 0.82, blue: 0.98, alpha: 1.0).cgColor,
        NSColor(red: 0.20, green: 0.50, blue: 0.95, alpha: 1.0).cgColor
    ] as CFArray
    let moonLocations: [CGFloat] = [0.0, 0.45, 1.0]
    if let moonGradient = CGGradient(colorsSpace: colorSpace, colors: moonColors, locations: moonLocations) {
        ctx.drawLinearGradient(moonGradient,
                               start: CGPoint(x: moonCenter.x - outerRadius, y: moonCenter.y + outerRadius),
                               end: CGPoint(x: moonCenter.x + outerRadius, y: moonCenter.y - outerRadius),
                               options: [])
    }
    ctx.restoreGState()

    // Add gaming controller D-pad / star accent inside the inner curve
    let starCenter = CGPoint(x: size.width * 0.42, y: size.height * 0.44)
    let dpadSize = size.width * 0.08

    // Horizontal bar of plus
    ctx.setFillColor(NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 0.85).cgColor)
    let hBar = CGRect(x: starCenter.x - dpadSize * 0.6, y: starCenter.y - dpadSize * 0.2, width: dpadSize * 1.2, height: dpadSize * 0.4)
    let hPath = CGPath(roundedRect: hBar, cornerWidth: dpadSize * 0.1, cornerHeight: dpadSize * 0.1, transform: nil)
    ctx.addPath(hPath)
    ctx.fillPath()

    // Vertical bar of plus
    let vBar = CGRect(x: starCenter.x - dpadSize * 0.2, y: starCenter.y - dpadSize * 0.6, width: dpadSize * 0.4, height: dpadSize * 1.2)
    let vPath = CGPath(roundedRect: vBar, cornerWidth: dpadSize * 0.1, cornerHeight: dpadSize * 0.1, transform: nil)
    ctx.addPath(vPath)
    ctx.fillPath()

    ctx.restoreGState()

    image.unlockFocus()
    return image
}

let size = CGSize(width: 1024, height: 1024)
let icon = createMoonlightIcon(size: size)
if let tiffData = icon.tiffRepresentation,
   let bitmap = NSBitmapImageRep(data: tiffData),
   let pngData = bitmap.representation(using: .png, properties: [:]) {
    let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
    try? pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Generated 1024x1024 icon at \(outputPath)")
}
