// Gwen keys only: hold ⌃ dictate, ⌃⌃ hands-free, tap ⌃⇧ translate selection, hold ⌃ + ⇧⇧ translate speech, tap ⌃ cancel, ⌃⌘V paste last take.
import AppKit

enum Keys {
    enum Gesture { case none, dictate, translate, shiftBetween, spent }
    static let tapGap = 0.4
    static let holdAfter = 0.3
    static let mods: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
    static var gesture = Gesture.none
    static var started = false, handsFree = false, ender = false, solo = false
    static var lastTap: [Gesture: Date] = [:]
    static var holdTimer: Timer?
    static var tapTimer: Timer?

    static func install() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event($0) }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event($0); return $0 }
    }

    static func event(_ e: NSEvent) {
        if e.type == .keyDown {
            if pasteAgainChord(e) {
                hud.pasteLastAgain()
                return
            }
            return interrupt()
        }
        let now = e.modifierFlags.intersection(mods)
        switch (gesture, now) {
        case (.none, [.control]): begin(.dictate)
        case (.none, [.control, .shift]), (.dictate, [.control, .shift]), (.shiftBetween, [.control, .shift]):
            if gesture == .dictate { drop() }
            begin(.translate)
        case (.translate, [.control]):
            if !started && solo { armTranslateTap() }
            gesture = .shiftBetween
        case (_, []):
            if gesture == .translate && !started && solo {
                tapTimer?.invalidate(); tapTimer = nil
                hud.translateSelection(to: "")
            } else if gesture == .shiftBetween { firePendingTranslate() }
            else { end() }
            gesture = .none
        case (.none, [.shift]), (.dictate, [.control]), (.translate, [.control, .shift]), (.translate, [.shift]),
             (.shiftBetween, [.control]), (.spent, _):
            break
        default: interrupt()
        }
    }

    static func begin(_ g: Gesture) {
        gesture = g
        solo = true
        started = false
        handsFree = false
        if g == .translate {
            tapTimer?.invalidate()
            tapTimer = nil
            if hud.speechTranslate {
                started = true
                handsFree = true
                return hud.finishSpeechTranslate()
            }
            if Date().timeIntervalSince(lastTap[.translate] ?? .distantPast) < tapGap {
                lastTap[.translate] = nil
                started = true
                handsFree = true
                return hud.beginSpeechTranslate()
            }
            return
        }
        ender = ["dictating", "cleaning", "translating", "transcript"].contains(hud.state)
        if ender {
            started = true
            hud.acceptInsert = false
            if hud.speechTranslate { hud.cancelSpeechTranslate() }
            else {
                hud.apply("idle")
                emit("dictate cancel")
            }
            return
        }
        if Date().timeIntervalSince(lastTap[.dictate] ?? .distantPast) < tapGap {
            lastTap[.dictate] = nil
            started = true
            handsFree = true
            return emit("dictate free")
        }
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdAfter, repeats: false) { _ in
            guard solo, gesture == .dictate else { return }
            started = true
            emit("dictate hold")
        }
    }

    static func end() {
        holdTimer?.invalidate()
        guard gesture == .dictate else { return }
        if started && !handsFree && !ender {
            emit("dictate release")
        } else if !started && solo {
            if hud.cancelBar() { return }
            lastTap[.dictate] = Date()
        }
    }

    static func armTranslateTap() {
        tapTimer?.invalidate()
        lastTap[.translate] = Date()
        tapTimer = Timer.scheduledTimer(withTimeInterval: tapGap, repeats: false) { _ in
            tapTimer = nil
            lastTap[.translate] = nil
            guard !hud.speechTranslate else { return }
            hud.translateSelection(to: "")
        }
    }

    static func firePendingTranslate() {
        guard tapTimer != nil else { return }
        tapTimer?.invalidate()
        tapTimer = nil
        lastTap[.translate] = nil
        guard !hud.speechTranslate else { return }
        hud.translateSelection(to: "")
    }

    static func drop() {
        holdTimer?.invalidate()
        tapTimer?.invalidate()
        tapTimer = nil
        if gesture == .translate { started = false; handsFree = false; return }
        if gesture == .dictate && started && !handsFree && !ender {
            hud.acceptInsert = false
            hud.apply("idle")
            emit("dictate cancel")
        }
        started = false
    }

    static func interrupt() {
        if hud.speechTranslate { hud.cancelSpeechTranslate() }
        drop()
        solo = false
        if gesture != .none { gesture = .spent }
        lastTap = [:]
    }

    /// ⌃⌘V — paste the newest take again (into the current focus).
    static func pasteAgainChord(_ e: NSEvent) -> Bool {
        let now = e.modifierFlags.intersection(mods)
        return now == [.control, .command] && e.keyCode == 9 && !e.isARepeat  // V
    }
}
