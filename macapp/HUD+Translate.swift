// Selection translate (⌃⇧) and speech translate (⌃⇧⇧).
import AppKit
import Carbon

private var waiting: [Any] = []
private var waitTimer: Timer?
private var clipSeen = NSPasteboard.general.changeCount
private var clipCopiedAt = Date.distantPast
private var clipOurs = 0
private var onceLang: String?
private var speechOn = false
private var selecting = false
private var translatePid: pid_t = 0
private var translateFocus: AXUIElement?
private var translateSelRange: CFRange?
private var translateLive = false

extension HUD {
    var translateTarget: String { resolveTranslate(translateChoice()) }
    var speechTranslate: Bool { speechOn }
    var translateWaitingForSelection: Bool { !waiting.isEmpty }
    var selectionTranslateInFlight: Bool {
        state == "translating" && !speechOn && waiting.isEmpty && !selecting
    }

    /// Short label for the translate-to preference on the idle (and menu) chip: Mac / Key / EN…
    func translatePrefChip() -> String {
        let c = translateChoice()
        if c == "mac" { return "Mac" }
        if c == "keyboard" { return "Key" }
        return (supportedLanguage(c) ?? c).uppercased()
    }

    func translateToMenu() -> NSMenu {
        let menu = NSMenu()
        addTranslateChoices(menu, mark: true)
        return menu
    }

    func addTranslateChoices(_ menu: NSMenu, mark: Bool) {
        let choice = translateChoice()
        for (i, row) in translateChoices().enumerated() {
            if i == 2 { menu.addItem(.separator()) }
            let m = NSMenuItem(title: row.title, action: #selector(pickTranslateTo(_:)), keyEquivalent: "")
            m.representedObject = row.value
            m.target = self
            m.state = mark && row.value == choice ? .on : .off
            menu.addItem(m)
        }
    }

    @objc func pickTranslateTo(_ sender: NSMenuItem) {
        chooseTranslate(sender.representedObject as? String ?? "mac")
    }

    func chooseTranslate(_ choice: String) {
        UserDefaults.standard.set(choice.isEmpty ? "mac" : choice, forKey: "translateTo")
        onceLang = nil
        if state == "dictating" || state == "idle" {
            view.chip = chipLabel(translateTarget)
            resizeBarInPlace()
        } else if state == "translating" && !view.chip.isEmpty {
            view.chip = chipLabel(onceLang ?? translateTarget)
        }
        if !waiting.isEmpty { armWait() }
        if state == "transcript" && !original.isEmpty { retranslate(to: translateTarget) }
        SettingsWindow.refresh()
    }

    func chipClicked() {
        if view.mode == "transcript" { showLangMenu() }
        else if ["translating", "dictating", "idle"].contains(view.mode) { showTranslateMenu() }
    }

    func showTranslateMenu() {
        emit("menu on")
        translateToMenu().popUp(positioning: nil, at: NSPoint(x: view.chipRect.minX, y: view.chipRect.minY), in: view)
        emit("menu off")
        if !waiting.isEmpty { armWait() }
    }

    func applyState(_ s: String) {
        guard speechOn else { return apply(s) }
        switch s {
        case "dictating":
            rememberDictationTarget()
            acceptInsert = true
            view.chip = chipLabel(onceLang ?? translateTarget)
            view.hintNote = "Stops when you stop talking · tap ⌃⇧ to stop · tap the language to change it"
            apply("translating", text: "Listening…")
        case "cleaning":
            view.chip = ""
            view.hintNote = ""
            apply("translating", text: "Translating…")
        case "idle":
            speechOn = false
            view.chip = ""
            view.hintNote = ""
            apply(s)
        default:
            apply(s)
        }
    }

    func beginSpeechTranslate() {
        guard #available(macOS 15, *) else { return flash("Translating needs macOS 15 or later.") }
        speechOn = true
        acceptInsert = true
        rememberDictationTarget()
        onceLang = nil
        stopWaitingForSelection()
        view.chip = chipLabel(translateTarget)
        view.hintNote = "Stops when you stop talking · tap ⌃⇧ to stop · tap the language to change it"
        apply("translating", text: "Listening…")
        emit("dictate free")
    }

    func finishSpeechTranslate() {
        guard speechOn else { return }
        view.chip = ""
        view.hintNote = ""
        apply("translating", text: "Translating…")
        emit("dictate end")
    }

    func cancelSpeechTranslate() {
        guard speechOn else { return }
        speechOn = false
        acceptInsert = false
        view.chip = ""
        view.hintNote = ""
        apply("idle")
        emit("dictate cancel")
    }

    func takeSpeechTranslate() -> Bool {
        let on = speechOn
        speechOn = false
        return on
    }

    func translateSelection(to code: String) {
        if speechOn { return finishSpeechTranslate() }
        // Duplicate ⌃⇧: only stop wait-for-selection. Do not cancel an in-flight translate.
        if state == "translating" {
            if !waiting.isEmpty { return apply("idle") }
            return
        }
        if selecting { return }
        guard #available(macOS 15, *) else { return flash("Translating needs macOS 15 or later.") }
        onceLang = code.isEmpty ? nil : code
        view.chip = ""
        view.hintNote = ""
        noteClipboard()
        let copied = Date().timeIntervalSince(clipCopiedAt) < 60 ? NSPasteboard.general.string(forType: .string) : nil
        // Capture before apply("translating"): showing the bar used to resign focus so AX / ⌘C saw nothing.
        selecting = true
        rememberTranslateTarget()
        selection { [weak self] text in
            selecting = false
            guard let self, !speechOn else { return }
            self.apply("translating", text: "Translating…")
            guard self.state == "translating", !speechOn else { return }
            let to = onceLang ?? self.translateTarget
            // Live selection always replaces in place. Recent clipboard only when nothing is selected.
            if let text {
                if translateSelRange == nil { self.refreshTranslateSelectionRange() }
                translateLive = true
                self.translate(text, to: to)
            } else if let copied, !copied.isEmpty {
                clearTranslateTarget()
                self.translateCopied(copied, to: to)
            } else {
                self.waitForSelection()
            }
        }
    }

    func translateCopied(_ text: String, to code: String) {
        clipCopiedAt = .distantPast
        translator.translate(text, to: code) { [weak self] outcome in
            guard let self, self.state == "translating" else { return }
            self.apply("idle")
            switch outcome {
            case .unchanged:
                FileHandle.standardError.write("translate: end same-lang (copied)\n".data(using: .utf8)!)
                let name = LANGS.first { sameLanguage($0.code, code) }?.name ?? code
                self.showGuide("That's already in \(name).", hideAfter: 3)
            case .failed:
                FileHandle.standardError.write("translate: end failed (copied)\n".data(using: .utf8)!)
                self.showGuide("Couldn't translate that.", hideAfter: 3)
            case .translated(let out):
                FileHandle.standardError.write("translate: end copied\n".data(using: .utf8)!)
                self.ownClipboard(true)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(out, forType: .string)
                self.ownClipboard(false)
                self.showGuide("Translated and copied.", hideAfter: 3)
            }
        }
    }

    func watchClipboard() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshTranslateChip()
            self?.noteClipboard()
        }
    }

    func refreshTranslateChip() {
        guard state == "translating" || state == "dictating" || state == "idle", !view.chip.isEmpty, onceLang == nil,
              translateChoice() == "keyboard" else { return }
        let label = chipLabel(translateTarget)
        if view.chip != label {
            view.chip = label
            if state == "idle" { resizeBarInPlace() }
        }
    }

    func noteClipboard() {
        let n = NSPasteboard.general.changeCount
        guard n != clipSeen else { return }
        clipSeen = n
        if clipOurs == 0 { clipCopiedAt = Date() }
    }

    func ownClipboard(_ begin: Bool) {
        clipOurs = max(0, clipOurs + (begin ? 1 : -1))
        if !begin { clipSeen = NSPasteboard.general.changeCount }
    }

    func waitForSelection() {
        view.chip = chipLabel(onceLang ?? translateTarget)
        apply("translating", text: "Select text to translate")
        var down = NSPoint.zero
        let check = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self, self.state == "translating", !waiting.isEmpty else { return }
                self.selection { text in
                    guard let text, self.state == "translating", !waiting.isEmpty else { return }
                    self.rememberTranslateTarget()
                    if translateSelRange == nil { self.refreshTranslateSelectionRange() }
                    translateLive = true
                    self.translate(text, to: onceLang ?? self.translateTarget)
                }
            }
        }
        waiting = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in down = NSEvent.mouseLocation },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { e in
                let p = NSEvent.mouseLocation
                if hypot(p.x - down.x, p.y - down.y) > 4 || e.clickCount >= 2 { check() }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] e in
                if Int(e.keyCode) == kVK_Escape { return self?.apply("idle") ?? () }
                let f = e.modifierFlags
                if f.contains(.shift) || (f.contains(.command) && e.charactersIgnoringModifiers == "a") { check() }
            },
        ].compactMap { $0 }
        armWait()
    }

    func armWait() {
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.state == "translating", !waiting.isEmpty else { return }
            clearTranslateTarget()
            self.flash("Nothing selected, so nothing to translate.")
        }
    }

    func stopWaitingForSelection() {
        waiting.forEach(NSEvent.removeMonitor)
        waiting = []
        waitTimer?.invalidate()
        waitTimer = nil
    }

    func translate(_ text: String, to code: String) {
        stopWaitingForSelection()
        view.chip = ""
        view.hintNote = ""
        apply("translating", text: "Translating…")
        translator.translate(text, to: code) { [weak self] outcome in
            guard let self, self.state == "translating" else { return }
            switch outcome {
            case .unchanged:
                FileHandle.standardError.write("translate: end same-lang\n".data(using: .utf8)!)
                clearTranslateTarget()
                self.apply("idle")
                let name = LANGS.first { sameLanguage($0.code, code) }?.name ?? code
                self.showGuide("That's already in \(name).", hideAfter: 3)
            case .failed:
                FileHandle.standardError.write("translate: end failed\n".data(using: .utf8)!)
                clearTranslateTarget()
                self.apply("idle")
                self.showGuide("Couldn't translate that.", hideAfter: 3)
            case .translated(let out):
                self.replaceSelection(out) { [weak self] ok in
                    guard let self, self.state == "translating" else { return }
                    if ok {
                        FileHandle.standardError.write("translate: end replaced\n".data(using: .utf8)!)
                        self.apply("idle")
                    } else {
                        FileHandle.standardError.write("translate: end clipboard\n".data(using: .utf8)!)
                        self.showCopiedTranscript(out)
                    }
                }
            }
        }
    }

    func selection(_ done: @escaping (String?) -> Void) {
        if let el = focusedElement() {
            var val: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &val) == .success,
               let s = val as? String, !s.isEmpty {
                return done(s)
            }
        }
        // Wait until ⌃/⇧ are up so ⌘C is not eaten by a still-held ⌃⇧.
        waitModsClear(retries: 12) { [weak self] in
            guard let self else { return done(nil) }
            self.copySelection(done)
        }
    }

    func waitModsClear(retries: Int, then: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.control, .shift])
        if held.isEmpty || retries <= 0 { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return then() }
            self.waitModsClear(retries: retries - 1, then: then)
        }
    }

    func copySelection(_ done: @escaping (String?) -> Void) {
        primeFocus()
        let pb = NSPasteboard.general, before = pb.changeCount, previous = pb.string(forType: .string)
        ownClipboard(true)
        key(kVK_ANSI_C)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            defer { self?.ownClipboard(false) }
            guard pb.changeCount != before else { return done(nil) }
            let copied = pb.string(forType: .string)
            pb.clearContents()
            if let p = previous { pb.setString(p, forType: .string) }
            done(copied?.isEmpty == false ? copied : nil)
        }
    }

    func rememberTranslateTarget() {
        primeFocus()
        translatePid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        translateFocus = focusedElement()
        translateSelRange = nil
        translateLive = false
        refreshTranslateSelectionRange()
    }

    func refreshTranslateSelectionRange() {
        let el = translateFocus ?? focusedElement()
        guard let el else { return }
        if translateFocus == nil { translateFocus = el }
        var sel: AnyObject?, range = CFRange()
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sel) == .success,
           let sel, AXValueGetValue(sel as! AXValue, .cfRange, &range), range.length > 0 {
            translateSelRange = range
        }
    }

    func clearTranslateTarget() {
        translatePid = 0
        translateFocus = nil
        translateSelRange = nil
        translateLive = false
    }

    func retargetTranslateField() {
        if translatePid != 0, let app = NSRunningApplication(processIdentifier: translatePid) {
            if #available(macOS 14, *) { app.activate() } else { app.activate(options: [.activateIgnoringOtherApps]) }
        }
        primeFocus()
        guard let el = translateFocus else { return }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if var range = translateSelRange, let ax = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, ax)
        }
    }

    /// Electron/Chrome often report AX success without changing the field — verify or refuse.
    func setSelectedText(_ el: AXUIElement, _ text: String) -> Bool {
        var beforeVal: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &beforeVal)
        let before = beforeVal as? String

        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }

        var afterVal: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &afterVal)
        let after = afterVal as? String

        var afterSel: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &afterSel)
        let afterSelected = afterSel as? String ?? ""

        if before != nil || after != nil {
            if before != after { return true }
            if afterSelected == text { return true }
            FileHandle.standardError.write(
                "translate: AX set ignored (\(focusDescription()))\n".data(using: .utf8)!)
            return false
        }
        FileHandle.standardError.write(
            "translate: AX set unverified, will paste (\(focusDescription()))\n".data(using: .utf8)!)
        return false
    }

    func elementIsEditable(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let r = role as? String, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) {
            return true
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue && (role as? String) != "AXStaticText" {
            return true
        }
        return false
    }

    func replaceSelection(_ text: String, done: @escaping (Bool) -> Void) {
        let tryAx: (AXUIElement?) -> Bool = { el in
            guard let el else { return false }
            return self.setSelectedText(el, text)
        }
        if tryAx(translateFocus) || tryAx(focusedElement()) {
            clearTranslateTarget()
            return done(true)
        }
        retargetTranslateField()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return done(false) }
            self.retargetTranslateField()
            if tryAx(translateFocus) || tryAx(self.focusedElement()) {
                clearTranslateTarget()
                return done(true)
            }
            let canPaste = self.elementIsEditable(translateFocus) || self.focusedIsEditable() || translateLive
            guard canPaste else {
                FileHandle.standardError.write(
                    "translate: replace failed (\(self.focusDescription()))\n".data(using: .utf8)!)
                clearTranslateTarget()
                return done(false)
            }
            let el = translateFocus ?? self.focusedElement()
            var selText: AnyObject?
            let hasSel = el != nil
                && AXUIElementCopyAttributeValue(el!, kAXSelectedTextAttribute as CFString, &selText) == .success
                && (selText as? String)?.isEmpty == false
            if !hasSel && translateSelRange == nil && !translateLive {
                FileHandle.standardError.write(
                    "translate: selection gone, not pasting (\(self.focusDescription()))\n".data(using: .utf8)!)
                clearTranslateTarget()
                return done(false)
            }
            if !hasSel && translateSelRange == nil {
                FileHandle.standardError.write(
                    "translate: AX selection invisible, pasting anyway (live) (\(self.focusDescription()))\n"
                        .data(using: .utf8)!)
            }
            self.paste(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.clearTranslateTarget()
                done(true)
            }
        }
    }

    func flash(_ text: String) {
        apply("transcript", text: text)
        view.mode = "translating"
        view.text = text
        transcriptHideTimer?.invalidate()
        transcriptHideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self, self.view.text == text else { return }
            self.apply("idle")
        }
    }
}
