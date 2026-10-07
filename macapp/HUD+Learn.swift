// Learn from edits after Gwen pastes (Accessibility). Emits `compose fixed <json>` for a future listener.
import AppKit

let editWatch = EditWatch()

final class EditWatch {
    var field: AXUIElement?
    var pasted = "", pre = "", post = "", last = ""
    var began = Date()
    var timer: Timer?
    var pasteKey: Any?
    var gen = 0

    func pastedInto(_ el: AXUIElement?, _ text: String) {
        conclude()
        guard let el else { return }
        let mine = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            guard mine == gen else { return }
            guard let v = value(el), let r = where_(text, in: v, of: el) else {
                return note("can't read this field back: nothing to learn here")
            }
            let s = v as NSString
            (field, pasted, pre, post, last, began) = (el, text, s.substring(to: r.location), s.substring(from: r.location + r.length), v, Date())
            note("watching the field for your fixes")
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func copied(_ text: String) {
        conclude()
        pasteKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.charactersIgnoringModifiers == "v", e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
            if hud.state == "transcript" { hud.apply("idle") }
            self?.pastedInto(hud.focusedElement(), text)
        }
    }

    func where_(_ text: String, in v: String, of el: AXUIElement) -> NSRange? {
        let s = v as NSString, n = (text as NSString).length
        var sel: AnyObject?, caret = CFRange()
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sel) == .success, let sel,
           AXValueGetValue(sel as! AXValue, .cfRange, &caret), caret.location >= n, caret.location <= s.length,
           s.substring(with: NSRange(location: caret.location - n, length: n)) == text {
            return NSRange(location: caret.location - n, length: n)
        }
        let r = s.range(of: text, options: .backwards)
        return r.location == NSNotFound ? nil : r
    }

    func tick() {
        guard let el = field else { return }
        let here = hud.focusedElement().map { CFEqual($0, el) } ?? false
        let now = value(el).flatMap(part)
        if let now, !now.isEmpty { last = pre + now + post }
        let why = !here ? "you left the field" : now == nil ? "the text before it changed" : now!.isEmpty ? "cleared or sent"
            : Date().timeIntervalSince(began) > 120 ? "two minutes" : ""
        if !why.isEmpty { conclude(why) }
    }

    func part(_ v: String) -> String? {
        guard v.hasPrefix(pre) else { return nil }
        let rest = v.dropFirst(pre.count)
        return String(!post.isEmpty && rest.hasSuffix(post) ? rest.dropLast(post.count) : rest)
    }

    func conclude(_ why: String = "a new dictation") {
        gen += 1
        timer?.invalidate()
        timer = nil
        if let k = pasteKey { NSEvent.removeMonitor(k) }
        pasteKey = nil
        guard field != nil else { return }
        field = nil
        guard let fixed = part(last), fixed != pasted,
              let d = try? JSONSerialization.data(withJSONObject: ["heard": pasted, "text": fixed]),
              let json = String(data: d, encoding: .utf8) else {
            return note("done after \(Int(Date().timeIntervalSince(began))) s (\(why)): nothing changed")
        }
        note("done after \(Int(Date().timeIntervalSince(began))) s (\(why)): the field changed, sent to the listener")
        emit("compose fixed " + json)
    }

    func value(_ el: AXUIElement) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success, let s = v as? String,
              s.count <= 20_000 else { return nil }
        return s
    }

    func note(_ line: String) { FileHandle.standardError.write("learn: \(line)\n".data(using: .utf8)!) }
}
