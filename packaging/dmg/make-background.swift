// Draws the Brim.dmg window background: drag-to-Applications at the top, first-open steps below.
//   swift packaging/dmg/make-background.swift   -> packaging/dmg/background.tiff (1x + 2x)
// The icon positions here must match packaging/dmg/settings.py.
import AppKit

let size = NSSize(width: 660, height: 440)
let ink = NSColor(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
let soft = NSColor(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255, alpha: 1)
let paper = NSColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255, alpha: 1)

func text(_ string: String, _ font: NSFont, _ color: NSColor, at point: NSPoint, width: CGFloat, center: Bool = false) {
    let style = NSMutableParagraphStyle()
    style.alignment = center ? .center : .left
    style.lineSpacing = 2
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    NSAttributedString(string: string, attributes: attributes)
        .draw(with: NSRect(x: point.x, y: point.y, width: width, height: 60), options: [.usesLineFragmentOrigin])
}

func draw() {
    paper.setFill()
    NSRect(origin: .zero, size: size).fill()

    text("Drag Brim to Applications", .systemFont(ofSize: 21, weight: .bold), ink, at: NSPoint(x: 0, y: 28), width: size.width, center: true)
    text("Then open it from your Applications folder.", .systemFont(ofSize: 13, weight: .medium), soft,
         at: NSPoint(x: 0, y: 58), width: size.width, center: true)

    // Arrow between the two icons (Brim at x 170, Applications at x 490, both at y 175).
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: 175))
    arrow.line(to: NSPoint(x: 392, y: 175))
    arrow.move(to: NSPoint(x: 378, y: 163))
    arrow.line(to: NSPoint(x: 394, y: 175))
    arrow.line(to: NSPoint(x: 378, y: 187))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    soft.withAlphaComponent(0.55).setStroke()
    arrow.stroke()

    // First-open card.
    let card = NSRect(x: 40, y: 280, width: 580, height: 132)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    NSColor.black.withAlphaComponent(0.08).setStroke()
    let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
    border.lineWidth = 1
    border.stroke()

    text("First time opening Brim?", .systemFont(ofSize: 14, weight: .bold), ink, at: NSPoint(x: 62, y: 296), width: 400)
    let steps = [
        "Open Brim from Applications.",
        "If macOS says it can't verify Brim, click Done.",
        "Open System Settings › Privacy & Security, then click Open Anyway.",
    ]
    for (index, step) in steps.enumerated() {
        let y = CGFloat(324 + index * 24)
        let badge = NSRect(x: 62, y: y, width: 18, height: 18)
        ink.setFill()
        NSBezierPath(ovalIn: badge).fill()
        text("\(index + 1)", .systemFont(ofSize: 11, weight: .bold), paper, at: NSPoint(x: badge.minX, y: y + 2), width: 18, center: true)
        text(step, .systemFont(ofSize: 13, weight: .medium), ink, at: NSPoint(x: 90, y: y + 1), width: 520)
    }
    text("Only needed once. Brim isn't notarized by Apple yet.", .systemFont(ofSize: 11, weight: .medium), soft,
         at: NSPoint(x: 0, y: 418), width: size.width, center: true)
}

func png(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    // Top-left origin, like the Finder window the image sits in.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let one = folder.appendingPathComponent("background.png"), two = folder.appendingPathComponent("background@2x.png")
try! png(scale: 1).write(to: one)
try! png(scale: 2).write(to: two)
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck", one.path, two.path, "-out", folder.appendingPathComponent("background.tiff").path]
try! tiff.run()
tiff.waitUntilExit()
try? FileManager.default.removeItem(at: one)
try? FileManager.default.removeItem(at: two)
print("Wrote \(folder.appendingPathComponent("background.tiff").path)")
