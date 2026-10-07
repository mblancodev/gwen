// Gwen bottom bar: idle (language chip) / dictating / cleaning / translating / transcript.
import AppKit

final class PillView: NSView {
    var mode = "idle" { didSet { needsDisplay = true; pinned = false; onHint?(false) } }
    var onHint: ((Bool) -> Void)?
    var onBar: ((Bool) -> Void)?
    var onTranscript: (() -> Void)?
    var onChip: (() -> Void)?
    var chip = "" { didSet { needsDisplay = true } }
    var hintNote = "" { didSet { needsDisplay = true } }
    var pinned = false
    var text = "" { didSet { needsDisplay = true } }
    var levels = [CGFloat](repeating: 0.08, count: 5)
    var phase: CGFloat = 0
    var tab = false { didSet { needsDisplay = true } }
    var tabUp = false { didSet { needsDisplay = true } }
    var tabRise: CGFloat = 1 { didSet { needsDisplay = true } }
    var onTab: (() -> Void)?
    var tabStart = NSPoint.zero
    var tabFired = false
    var pillTop: CGFloat { bounds.maxY - (tab ? PillView.tabH : 0) }
    /// Dock grabber.
    static let tabH: CGFloat = 9, tabW: CGFloat = 18, fillet: CGFloat = 4
    static let iconWidth: CGFloat = 16 + 5 * 6 + 8
    static let maxWidth: CGFloat = 560
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let chipFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let spoken = ["idle": "Listening", "dictating": "Listening", "cleaning": "Running",
                         "translating": "Running", "transcript": "Done", "paused": "Listening"]

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Gwen" }
    override func accessibilityValue() -> Any? {
        if tab && tabUp { return "Docked. Click the arrow tab to show Gwen." }
        let said = labelString().string.isEmpty ? PillView.spoken[mode] ?? "" : labelString().string
        return [said, hint].filter { !$0.isEmpty }.joined(separator: ". ")
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hint: String {
        if (mode == "translating" || mode == "dictating") && !hintNote.isEmpty { return hintNote }
        return ["dictating": "Let go of ⌃ to paste · tap ⌃ to cancel · tap the language to change it",
                "cleaning": "Tap ⌃ to cancel",
                "translating": "Tap ⌃⇧ or Esc to stop · tap the language to change it",
                "transcript": "Copied · click bar or ⌃⌘V to paste again · tap ⌃ to close"][mode] ?? ""
    }
    var tight: Bool { ["dictating", "cleaning", "idle"].contains(mode) }
    var pad: CGFloat { tight ? 12 : 16 }
    var infoRect: NSRect { NSRect(x: bounds.maxX - pad - 16, y: pillTop - 27, width: 16, height: 16) }
    var hintWidth: CGFloat { (hint.isEmpty ? 0 : 24) + (showsChip ? chipWidth + 8 : 0) }
    var showsChip: Bool { !chip.isEmpty && (mode == "transcript" || mode == "translating" || mode == "dictating" || mode == "idle") }
    var chipText: NSAttributedString {
        NSAttributedString(string: chip + " ▾", attributes: [.font: PillView.chipFont, .foregroundColor: NSColor.white])
    }
    var chipWidth: CGFloat { ceil(chipText.size().width) + 14 }
    /// Idle has no ⓘ: chip hugs the right pad. Slim idle bar centers the chip vertically.
    var chipRect: NSRect {
        let infoGap: CGFloat = hint.isEmpty ? 0 : 24
        let y = mode == "idle" ? max(2, (pillTop - 20) / 2) : pillTop - 29
        return NSRect(x: bounds.maxX - pad - infoGap - chipWidth, y: y, width: chipWidth, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["which": "bar"]))
        addTrackingArea(NSTrackingArea(rect: infoRect.insetBy(dx: -4, dy: -4), options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: ["which": "info"]))
    }
    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["which"] as? String == "info" {
            if !pinned && !hint.isEmpty { onHint?(true) }
        } else { onBar?(true) }
    }
    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["which"] as? String == "info" {
            if !pinned { onHint?(false) }
        } else { onBar?(false) }
    }
    override func mouseDown(with event: NSEvent) {
        if tabHit(event) { return tabDown() }
        if showsChip && chipRect.contains(convert(event.locationInWindow, from: nil)) { return onChip?() ?? () }
        if mode == "transcript" { return onTranscript?() ?? () }
        guard !hint.isEmpty, infoRect.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) else { return }
        pinned.toggle()
        onHint?(pinned)
    }

    func labelString() -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: PillView.font, .foregroundColor: NSColor.white])
        if mode == "transcript" {
            out.append(NSAttributedString(string: "\nCopied · click to paste again",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                       .foregroundColor: NSColor(white: 1, alpha: 0.55)]))
        }
        return out
    }

    var preferredSize: NSSize {
        let s = pillSize
        return tab ? NSSize(width: s.width, height: s.height + PillView.tabH) : s
    }
    var pillSize: NSSize {
        if stacked {
            let r = labelString().boundingRect(with: NSSize(width: PillView.maxWidth - 2 * pad, height: 8 * 18),
                                               options: [.usesLineFragmentOrigin])
            return NSSize(width: PillView.maxWidth, height: 38 + ceil(r.height) + 12)
        }
        let textMax = PillView.maxWidth - PillView.iconWidth - 20
        let r = labelString().boundingRect(with: NSSize(width: textMax, height: 6 * 18), options: [.usesLineFragmentOrigin])
        if mode == "idle" {
            let chipExtra: CGFloat = showsChip ? chipWidth + 8 : 0
            if !showsChip { return NSSize(width: 60, height: 24) }
            return NSSize(width: pad + 30 + chipExtra + pad, height: 24)
        }
        if tight && labelString().length == 0 {
            return NSSize(width: pad + 30 + hintWidth + pad, height: 38)
        }
        let left: CGFloat = tight ? pad + 36 : PillView.iconWidth
        return NSSize(width: left + ceil(r.width) + (tight ? pad : 20) + hintWidth, height: max(38, ceil(r.height) + 20))
    }

    var sine: Bool { ["idle", "cleaning", "translating"].contains(mode) }
    var stacked: Bool {
        sine && labelString().size().width > PillView.maxWidth - PillView.iconWidth - 20 - hintWidth
    }
    var level: CGFloat { levels.reduce(0, +) / CGFloat(levels.count) }

    func body(_ r: NSRect) -> NSBezierPath {
        let rad = min(r.height / 2, 19), p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + rad, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad, startAngle: 270, endAngle: 360)
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - rad))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad, startAngle: 0, endAngle: 90)
        if tab && tabRise > 0 {
            let b = r.maxY, f = PillView.fillet, rr: CGFloat = 3, k = tabRise
            let x0 = bounds.midX - PillView.tabW / 2 - f, x1 = bounds.midX + PillView.tabW / 2 + f
            func pt(_ x: CGFloat, _ dy: CGFloat) -> NSPoint { NSPoint(x: x, y: b + dy * k) }
            let top = bounds.maxY - 0.5 - b
            p.line(to: pt(x1, 0))
            p.curve(to: pt(x1 - f, f), controlPoint1: pt(x1 - f * 0.55, 0), controlPoint2: pt(x1 - f, f * 0.45))
            p.line(to: pt(x1 - f, top - rr))
            p.curve(to: pt(x1 - f - rr, top), controlPoint1: pt(x1 - f, top - rr * 0.45), controlPoint2: pt(x1 - f - rr * 0.45, top))
            p.line(to: pt(x0 + f + rr, top))
            p.curve(to: pt(x0 + f, top - rr), controlPoint1: pt(x0 + f + rr * 0.45, top), controlPoint2: pt(x0 + f, top - rr * 0.45))
            p.line(to: pt(x0 + f, f))
            p.curve(to: pt(x0, 0), controlPoint1: pt(x0 + f, f * 0.45), controlPoint2: pt(x0 + f * 0.55, 0))
        }
        p.line(to: NSPoint(x: r.minX + rad, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: r.minX, y: r.minY + rad))
        p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.minY + rad), radius: rad, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    func drawBody(_ r: NSRect) {
        let p = body(r)
        NSColor(white: 0, alpha: 0.88).setFill()
        p.fill()
        if !tabUp {  // docked: no rim, the tab is plain black
            NSColor(white: 1, alpha: 0.15).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
        guard tab && tabRise > 0 else { return }
        let s: CGFloat = tabUp ? 1 : -1, mx = bounds.midX, my = r.maxY + (bounds.maxY - r.maxY) / 2 * tabRise
        let caret = NSBezierPath()
        caret.move(to: NSPoint(x: mx - 3, y: my - s * 1.5))
        caret.line(to: NSPoint(x: mx, y: my + s * 1.5))
        caret.line(to: NSPoint(x: mx + 3, y: my - s * 1.5))
        NSColor(white: 1, alpha: (tabUp ? 0.95 : 0.7) * tabRise).setStroke()
        caret.lineWidth = 1.2
        caret.lineCapStyle = .round
        caret.lineJoinStyle = .round
        caret.stroke()
    }

    func tabHit(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        // Generous hit: full tab width + padding; when docked, include a little of the pill body.
        let half = PillView.tabW / 2 + PillView.fillet + (tabUp ? 10 : 4)
        let low = pillTop - (tabUp ? 8 : 3)
        return tab && p.y >= low && abs(p.x - bounds.midX) <= half
    }
    func tabDown() { tabStart = NSEvent.mouseLocation; tabFired = false }
    override func mouseDragged(with event: NSEvent) {
        guard tab, tabStart != .zero, !tabFired else { return }
        let dy = NSEvent.mouseLocation.y - tabStart.y
        if tabUp ? dy > 6 : dy < -6 { tabFired = true; onTab?() }
    }
    override func mouseUp(with event: NSEvent) {
        defer { tabStart = .zero }
        if tab && tabStart != .zero && !tabFired { onTab?() }
    }

    override func draw(_ dirty: NSRect) {
        let r = NSRect(x: 0, y: 0, width: bounds.width, height: pillTop).insetBy(dx: 1, dy: 1)
        drawBody(r)
        let midY: CGFloat = mode == "idle" ? pillTop / 2 : pillTop - 19
        if sine {
            let wave = NSBezierPath()
            let amp: CGFloat = mode == "cleaning" || mode == "translating" ? 5 : 3
            let w: CGFloat = max(30, stacked ? bounds.width - 2 * pad - (hint.isEmpty ? 0 : 24) : 30)
            // Chip left-aligns the wave; else ⓘ or center.
            let x0: CGFloat = labelString().length == 0
                ? (showsChip ? pad : hint.isEmpty ? (bounds.width - w) / 2 : max(pad, infoRect.minX - 6 - w)) : pad
            let n = Int(w)
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(max(n, 1))
                let cycles: CGFloat = stacked ? (w / 45) : CGFloat(1.5)
                let envelope: CGFloat = CGFloat(0.35) + CGFloat(0.65) * sin(t * CGFloat.pi)
                let angle: CGFloat = t * CGFloat(2) * CGFloat.pi * cycles + phase
                let y: CGFloat = midY + amp * sin(angle) * envelope
                let pt = NSPoint(x: x0 + t * w, y: y)
                if i == 0 { wave.move(to: pt) } else { wave.line(to: pt) }
            }
            (sttDown || mode == "idle" ? offColor : gwenColor).setStroke()
            wave.lineWidth = 2
            wave.lineCapStyle = .round
            wave.stroke()
        } else if mode == "transcript" {
            lucideCopy(in: NSRect(x: 18, y: midY - 8, width: 16, height: 16), color: gwenColor)
        } else {
            var x: CGFloat = pad
            let active = mode == "dictating"
            let tint = sttDown ? offColor : gwenColor
            for (i, lv) in levels.enumerated() {
                let h = max(4, (active ? lv : 0.25 + 0.2 * CGFloat(i % 2)) * 22)
                (active ? tint : NSColor(white: 1, alpha: 0.6)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: midY - h / 2, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
                x += 6
            }
        }
        let s = labelString()
        let textX = stacked ? pad : (tight ? pad + 36 : PillView.iconWidth)
        let textW = stacked ? bounds.width - 2 * pad : bounds.width - textX - (tight ? pad : 20) - hintWidth
        if !hint.isEmpty {
            NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium).applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.6)])))?
                .draw(in: infoRect)
        }
        if showsChip {
            let rad: CGFloat = 10
            let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: rad, yRadius: rad)
            NSColor(white: 1, alpha: 0.16).setFill()
            chipPath.fill()
            chipText.draw(at: NSPoint(x: chipRect.minX + 7, y: chipRect.midY - chipText.size().height / 2))
        }
        let h = ceil(s.boundingRect(with: NSSize(width: textW, height: 8 * 18), options: [.usesLineFragmentOrigin]).height)
        let top = stacked ? pillTop - 38 : pillTop - 10
        s.draw(with: NSRect(x: textX, y: top - max(h, 17), width: textW, height: max(h, 17)),
               options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }
}

final class HintView: NSView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = tipColor.withAlphaComponent(0.97).cgColor
        layer?.cornerRadius = 8
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ text: String) -> NSSize {
        label.stringValue = text
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 10, y: 6))
        return NSSize(width: label.frame.width + 20, height: label.frame.height + 12)
    }
}
