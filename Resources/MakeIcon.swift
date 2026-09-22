// Renders the app icon (1024x1024 PNG): warm gradient squircle + white flame.
// Usage: swift MakeIcon.swift /path/out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(x: 0, y: 0, width: px, height: px)
let inset = full.insetBy(dx: 60, dy: 60)
let squircle = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)

// Background gradient (violet → hot orange)
let bg = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.95, alpha: 1), 0.0),
    (NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.95, alpha: 1), 0.55),
    (NSColor(calibratedRed: 0.55, green: 0.40, blue: 0.98, alpha: 1), 1.0))!
bg.draw(in: squircle, angle: -65)

// Soft inner highlight
squircle.addClip()
let glow = NSGradient(colorsAndLocations:
    (NSColor.white.withAlphaComponent(0.0), 0.0),
    (NSColor.white.withAlphaComponent(0.06), 0.55),
    (NSColor.white.withAlphaComponent(0.26), 1.0))!
glow.draw(in: inset, angle: 90)

// Flame symbol, tinted white
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let img = image.copy() as! NSImage
    img.isTemplate = false
    img.lockFocus()
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    img.unlockFocus()
    return img
}
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .bold)
if let sym = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let flame = tinted(sym, .white)
    let s = flame.size
    let scale = min(620 / s.width, 620 / s.height)
    let w = s.width * scale, h = s.height * scale
    let r = NSRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2 - 10, width: w, height: h)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 40
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    flame.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
}

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
