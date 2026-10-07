// Gwen colors, floating panels, screenshot visibility.
import AppKit

let gwenColor = NSColor(srgbRed: 0xD9 / 255, green: 0x36 / 255, blue: 0x4F / 255, alpha: 1)  // #D9364F
let tipColor = NSColor(srgbRed: 0x25 / 255, green: 0x30 / 255, blue: 0x47 / 255, alpha: 1)
let offColor = NSColor(white: 0.55, alpha: 0.9)
var sttDown = false
var hudVisibleInCaptures = false

func hexColor(_ hex: String) -> NSColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

var reduceMotion: Bool {
    ProcessInfo.processInfo.environment["GWEN_REDUCE_MOTION"] == "1"
        || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

func hudSharingType() -> NSWindow.SharingType { hudVisibleInCaptures ? .readOnly : .none }

func applyHudSharing(statusWindow: NSWindow? = nil) {
    let t = hudSharingType()
    for w in NSApp.windows { w.sharingType = t }
    statusWindow?.sharingType = t
}

/// Bar / tip / translator host: on screen but never the key window.
final class GlancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func floatingPanel(_ size: NSSize) -> NSPanel {
    let frame = NSRect(origin: .zero, size: size)
    let p = GlancePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    p.becomesKeyOnlyIfNeeded = true
    p.isOpaque = false
    p.backgroundColor = .clear
    p.level = .statusBar
    p.ignoresMouseEvents = true
    p.sharingType = hudSharingType()
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    return p
}

func lucideCopy(in r: NSRect, color: NSColor) {
    let k = r.width / 24
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * k, y: r.maxY - y * k) }
    let front = NSBezierPath(roundedRect: NSRect(x: r.minX + 8 * k, y: r.maxY - 22 * k, width: 14 * k, height: 14 * k),
                             xRadius: 2 * k, yRadius: 2 * k)
    let back = NSBezierPath()
    back.move(to: p(4, 16))
    back.curve(to: p(2, 14), controlPoint1: p(2.9, 16), controlPoint2: p(2, 15.1))
    back.line(to: p(2, 4))
    back.curve(to: p(4, 2), controlPoint1: p(2, 2.9), controlPoint2: p(2.9, 2))
    back.line(to: p(14, 2))
    back.curve(to: p(16, 4), controlPoint1: p(15.1, 2), controlPoint2: p(16, 2.9))
    color.setStroke()
    for path in [front, back] {
        path.lineWidth = 2 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

func emit(_ s: String) { print(s); fflush(stdout) }
