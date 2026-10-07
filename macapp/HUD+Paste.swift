// Paste a transcript into the focused field, or show it copied on the bar.
import AppKit
import Carbon

let TERMINALS: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
                              "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
                              "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.termius-dmg.mac"]

func lineBreaks(_ arg: String) -> String { arg.replacingOccurrences(of: "\u{1E}", with: "\n") }

func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "[ \\t]*\\n[\\s]*", with: " ", options: .regularExpression)
}

extension HUD {
    func transcribed(_ text: String, watch: Bool = false) {
        _ = takeSpeechTranslate()
        guard acceptInsert else { return }
        let to = translateTarget
        original = text
        translator.translate(text, to: to) { [weak self] outcome in
            guard let self, self.acceptInsert else { return }
            switch outcome {
            case .translated(let out):
                self.deliver(out, lang: to, watch: watch)
            case .unchanged, .failed:
                self.deliver(text, lang: "", watch: watch)
            }
        }
    }

    func deliver(_ text: String, lang: String, watch: Bool = false) {
        shownLang = lang
        view.chip = chipLabel(lang)
        Takes.record(text, lang: lang)
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        // You moved to another app or desktop while it transcribed: the text follows you into the field that has
        // focus now. Only with no text field to take it is it shown copied instead.
        let moved = !sameDictationTarget()
        pasted = trusted && focusedIsEditable()
        if !pasted {
            FileHandle.standardError.write((trusted ? "paste: no text field has focus (\(focusDescription()))\n"
                                                    : "paste: Accessibility not granted\n").data(using: .utf8)!)
        } else if moved {
            FileHandle.standardError.write("paste: focus moved, pasting where you are (\(focusDescription()))\n".data(using: .utf8)!)
        }
        let learn = watch && lang.isEmpty && GwenConfig.bool("learn_from_edits")
        if pasted {
            var flat = sendsOnLineBreak() ? oneLine(text) : text
            let el = moved ? focusedElement() : dictationFocus ?? focusedElement()
            if let ctx = axCaretContext(el) {
                let adjusted = smartInsert(flat, before: ctx.before, after: ctx.after)
                if adjusted != flat {
                    FileHandle.standardError.write("insert: adjusted for caret context\n".data(using: .utf8)!)
                    flat = adjusted
                }
            }
            paste(flat)
            // Return after the paste has landed, so the message goes out without touching the keyboard.
            if GwenConfig.bool("auto_send") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.key(kVK_Return, flags: []) }
            }
            apply("idle")
            if learn { editWatch.pastedInto(el, flat) }
        } else {
            showCopiedTranscript(text)
            if learn { editWatch.copied(text) }
        }
    }

    func sendsOnLineBreak() -> Bool {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if TERMINALS.contains(app) || oneLineApps.contains(app) { return true }
        guard let el = focusedElement() else { return false }
        for attr in [kAXDescriptionAttribute, kAXRoleDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            var v: AnyObject?
            AXUIElementCopyAttributeValue(el, attr as CFString, &v)
            if let s = v as? String, s.range(of: "terminal", options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    func copy(_ text: String) {
        ownClipboard(true)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ownClipboard(false)
    }

    func showCopiedTranscript(_ text: String) {
        copy(text)
        apply("transcript", text: text)
        transcriptHideTimer?.invalidate()
        transcriptHideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, self.state == "transcript" else { return }
            self.apply("idle")
        }
    }

    func retranslate(to code: String) {
        guard !original.isEmpty else { return }
        translator.translate(original, to: code) { [weak self] outcome in
            guard let self else { return }
            self.shownLang = code
            self.view.chip = self.chipLabel(code)
            self.pasted = false
            switch outcome {
            case .translated(let out):
                Takes.record(out, lang: code)
                self.showCopiedTranscript(out)
            case .unchanged:
                Takes.record(self.original, lang: code)
                self.showCopiedTranscript(self.original)
            case .failed:
                self.flash("Couldn't translate that.")
            }
        }
    }

    func chipLabel(_ lang: String) -> String {
        (lang.isEmpty ? spokenLanguage(original) ?? "" : lang).split(separator: "-").first.map { $0.uppercased() } ?? ""
    }

    func langMenu() -> NSMenu {
        let menu = NSMenu()
        let spoken = spokenLanguage(original).map { Locale.current.localizedString(forIdentifier: $0) ?? $0 } ?? "spoken"
        let asSpoken = NSMenuItem(title: "As spoken (\(spoken))", action: #selector(pickLang(_:)), keyEquivalent: "")
        asSpoken.representedObject = ""
        asSpoken.target = self
        asSpoken.state = shownLang.isEmpty ? .on : .off
        menu.addItem(asSpoken)
        menu.addItem(.separator())
        addTranslateChoices(menu, mark: !shownLang.isEmpty)
        return menu
    }

    @objc func pickLang(_ sender: NSMenuItem) { retranslate(to: sender.representedObject as? String ?? "") }

    func showLangMenu() {
        langMenu().popUp(positioning: nil, at: NSPoint(x: view.chipRect.minX, y: view.chipRect.minY), in: view)
    }

    func paste(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        ownClipboard(true)
        pb.clearContents()
        pb.setString(text, forType: .string)
        key(kVK_ANSI_V)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            pb.clearContents()
            if let p = previous { pb.setString(p, forType: .string) }
            self?.ownClipboard(false)
        }
    }

    func key(_ code: Int, flags: CGEventFlags = .maskCommand) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    func focusDescription() -> String {
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        var role: AnyObject?
        if let el = focusedElement() { AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) }
        return "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), system-wide AX \(err.rawValue), "
            + "role \(role as? String ?? "none")"
    }

    func rememberDictationTarget() {
        editWatch.conclude()
        primeFocus()
        dictationPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        dictationFocus = focusedElement()
        let bundle = NSRunningApplication(processIdentifier: dictationPid)?.bundleIdentifier ?? ""
        FileHandle.standardError.write("paste: target \(bundle.isEmpty ? "none" : bundle), field \(dictationFocus == nil ? "not found" : "found")\n".data(using: .utf8)!)
        if !bundle.isEmpty { emit("target \(bundle)") }
    }

    func primeFocus() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func sameDictationTarget() -> Bool {
        guard dictationPid != 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == dictationPid,
              let want = dictationFocus, let now = focusedElement() else { return false }
        return CFEqual(want, now)
    }

    func focusedElement() -> AXUIElement? {
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let el = focused { return (el as! AXUIElement) }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        return (el as! AXUIElement)
    }

    func focusedIsEditable() -> Bool {
        guard let element = focusedElement() else { return false }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let r = role as? String, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue && (role as? String) != "AXStaticText"
    }

    // MARK: - Paste again / history

    func pasteLastAgain() {
        guard let take = Takes.last else {
            flash("No takes yet.")
            return
        }
        pasteStored(take)
    }

    func pasteStored(_ take: Take) {
        Takes.record(take.text, lang: take.lang)  // bump to newest
        original = take.text
        shownLang = take.lang
        view.chip = chipLabel(take.lang)
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        guard trusted, focusedIsEditable() else {
            showCopiedTranscript(take.text)
            return
        }
        var flat = sendsOnLineBreak() ? oneLine(take.text) : take.text
        let el = focusedElement()
        if let ctx = axCaretContext(el) {
            let adjusted = smartInsert(flat, before: ctx.before, after: ctx.after)
            if adjusted != flat { flat = adjusted }
        }
        paste(flat)
        apply("idle")
    }

    @objc func menuPasteLastAgain() { pasteLastAgain() }

    @objc func menuPasteTake(_ sender: NSMenuItem) {
        guard let take = sender.representedObject as? Take else { return }
        pasteStored(take)
    }

    func recentTakesMenu() -> NSMenu {
        let menu = NSMenu()
        let takes = Takes.load()
        if takes.isEmpty {
            let empty = NSMenuItem(title: "No takes yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for (i, take) in takes.prefix(12).enumerated() {
            let preview = takePreview(take.text)
            let title = "\(i + 1). \(preview)"
            let item = NSMenuItem(title: title, action: #selector(menuPasteTake(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = take
            menu.addItem(item)
        }
        return menu
    }

    func takePreview(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if one.count <= 48 { return one }
        let idx = one.index(one.startIndex, offsetBy: 45)
        return String(one[..<idx]) + "…"
    }
}
