// Gwen Settings pages.
import AppKit

extension SettingsWindow {
    func views(for s: Section) -> [NSView] {
        switch s {
        case .dictation: return dictationPage()
        case .translate: return translatePage()
        case .tone: return tonePage()
        case .shortcuts: return shortcutsPage()
        case .capture: return capturePage()
        }
    }

    func dictationPage() -> [NSView] {
        [header("Dictation", "How Gwen cleans and learns from what you say. Transcription itself stays on this Mac."),
         toggle("Learn from edits", "When you fix a paste in the same field, Gwen remembers the word.",
                GwenConfig.bool("learn_from_edits")) { on in GwenConfig.set("learn_from_edits", on); SettingsWindow.refresh() },
         toggle("Mute other audio while listening", "While you dictate and another app plays, the sound goes off; "
                + "it comes back when Gwen stops listening.", HUD.muteWhileListening) { [weak self] on in
             HUD.muteWhileListening = on; self?.hud?.updateMute(); SettingsWindow.refresh()
         },
         toggle("Write times, emoji, lists", "Turn spoken formatting into text when punctuation runs locally.",
                GwenConfig.bool("format_dictation")) { on in GwenConfig.set("format_dictation", on); SettingsWindow.refresh() },
         toggle("Keep corrected recordings", "Save audio you corrected, for later review. Off by default.",
                GwenConfig.bool("keep_corrected")) { on in GwenConfig.set("keep_corrected", on); SettingsWindow.refresh() },
         toggle("Polish with an agent", "An agent CLI on this Mac (Claude Code) tidies each take. Off by default: nothing leaves the Mac until you turn this on.",
                GwenConfig.bool("polish")) { on in GwenConfig.set("polish", on); SettingsWindow.refresh() },
         toggle("Apple Speech (macOS 26+)", "Use the Mac's SpeechAnalyzer instead of local whisper when available.",
                GwenConfig.bool("apple_speech")) { on in GwenConfig.set("apple_speech", on); SettingsWindow.refresh() }]
    }

    func translatePage() -> [NSView] {
        var v: [NSView] = [header("Translate", "On-device with Apple's Translation framework (macOS 15+).")]
        let choice = translateChoice()
        for row in translateChoices() {
            let on = row.value == choice
            v.append(toggle(row.title, row.value == "mac" || row.value == "keyboard"
                            ? "Follows this choice for ⌃, ⌃⇧ and the bar chip."
                            : "Always translate into \(row.title).", on) { [weak self] _ in
                self?.hud?.chooseTranslate(row.value)
            })
        }
        return v
    }

    func tonePage() -> [NSView] {
        var v: [NSView] = [
            header("Tone", "How Gwen finishes a take depends on the frontmost app when you start dictating. Settings here are the primary way to view and edit profiles."),
            note("Casual — chatty short lines. Formal — expands contractions. Verbatim — tidy only (terminals). Default — usual cleanup."),
            note("Built-in apps stay in the list; change the menu to override. Add any other app, then Remove to drop it. Saves to ~/.gwen/voice/tone.json."),
        ]
        let rows = Tone.listed()
        if rows.isEmpty {
            v.append(note("No profiles yet."))
        } else {
            for row in rows {
                v.append(toneRow(row.bundle, row.tone, overridden: row.overridden, custom: row.custom))
            }
        }
        v.append(addFrontmostToneButton())
        return v
    }

    func toneRow(_ bundle: String, _ tone: ToneKind, overridden: Bool, custom: Bool) -> NSView {
        let title = Tone.appTitle(bundle)
        let detail: String
        if custom {
            detail = "\(bundle) · added"
        } else if overridden {
            detail = "\(bundle) · changed from built-in"
        } else {
            detail = bundle
        }
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.autoenablesItems = false
        for t in ToneKind.allCases {
            pop.addItem(withTitle: t.title)
            pop.lastItem?.representedObject = t.rawValue
            pop.lastItem?.toolTip = t.blurb
        }
        pop.selectItem(withTitle: tone.title)
        let pick = SettingsAction { [weak pop] in
            guard let raw = pop?.selectedItem?.representedObject as? String,
                  let t = ToneKind(rawValue: raw) else { return }
            Tone.set(bundle, t)
            SettingsWindow.refresh()
        }
        actions.append(pick)
        pop.target = pick
        pop.action = #selector(SettingsAction.fire)

        // Remove custom apps; Reset built-ins that were overridden. Hidden for pristine built-ins.
        let canClear = custom || overridden
        let clearTitle = custom ? "Remove" : "Reset"
        let clearBtn = NSButton(title: clearTitle, target: nil, action: nil)
        clearBtn.bezelStyle = .inline
        clearBtn.isHidden = !canClear
        clearBtn.setAccessibilityLabel(clearTitle + " tone for " + title)
        if canClear {
            let clear = SettingsAction {
                Tone.remove(bundle)
                SettingsWindow.refresh()
            }
            actions.append(clear)
            clearBtn.target = clear
            clearBtn.action = #selector(SettingsAction.fire)
        }
        clearBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let controls = stack([pop, clearBtn], vertical: false, spacing: 8)
        return card(row(words(title, detail), controls))
    }

    func addFrontmostToneButton() -> NSView {
        let a = SettingsAction { [weak self] in
            // Prefer the app the user was in before opening Settings.
            let app = self?.returnTo ?? NSWorkspace.shared.frontmostApplication
            guard let bundle = app?.bundleIdentifier, !bundle.isEmpty, bundle != "app.gwen.hud" else {
                let alert = NSAlert()
                alert.messageText = "No frontmost app"
                alert.informativeText = "Switch to the app you want, then open Settings again and click Add frontmost app."
                alert.alertStyle = .informational
                alert.runModal()
                return
            }
            let name = Tone.appTitle(bundle)
            if Tone.listed().contains(where: { $0.bundle == bundle }) {
                let alert = NSAlert()
                alert.messageText = "\(name) is already listed"
                alert.informativeText = "Pick its tone in the menu above."
                alert.alertStyle = .informational
                alert.runModal()
                SettingsWindow.refresh()
                return
            }
            Tone.set(bundle, .default)
            SettingsWindow.refresh()
        }
        actions.append(a)
        let b = PillButton("Add frontmost app", target: a, action: #selector(SettingsAction.fire), primary: true)
        return stack([
            note("Adds the app you were using before this window opened (or the one in front now)."),
            b,
        ], spacing: 8)
    }

    func shortcutsPage() -> [NSView] {
        [header("Shortcuts", "Fixed for now — not editable."),
         note("Hold ⌃ — Dictate; let go to paste"),
         note("⌃⌃ or “Hey Gwen” — Dictate hands-free"),
         note("Tap ⌃⇧ — Translate the selection (or a recent copy)"),
         note("Hold ⌃, tap ⇧ twice — Translate what you say"),
         note("Tap ⌃ — Cancel: nothing is pasted or started"),
         note("⌃⌘V — Paste the last take again"),
         note("Menu → Recent takes — browse and re-paste")]
    }

    func capturePage() -> [NSView] {
        [header("Capture", "For demos and Twitter clips."),
         toggle("Show bar in screenshots and screen shares",
                "Off by default so a call never sees Gwen's bar. On for demos.",
                hudVisibleInCaptures) { [weak self] on in self?.hud?.setHudVisible(on) }]
    }

    func header(_ title: String, _ text: String) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        return stack([t, wrap(text, size: 12, width: SettingsWindow.width)], spacing: 6)
    }

    func note(_ s: String) -> NSView { wrap(s, size: 12, width: SettingsWindow.width, color: .secondaryLabelColor) }

    func wrap(_ s: String, size: CGFloat, width: CGFloat, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = NSFont.systemFont(ofSize: size)
        t.textColor = color
        t.preferredMaxLayoutWidth = width
        t.isSelectable = false
        return t
    }

    func words(_ title: String, _ detail: String) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        t.lineBreakMode = .byTruncatingTail
        return stack([t, wrap(detail, size: 11, width: SettingsWindow.width - 130)], spacing: 2)
    }

    func toggle(_ title: String, _ detail: String, _ on: Bool, _ act: @escaping (Bool) -> Void) -> NSView {
        let sw = NSSwitch()
        sw.state = on ? .on : .off
        sw.setAccessibilityLabel(title)
        let a = SettingsAction { [weak sw] in act(sw?.state == .on) }
        actions.append(a)
        sw.target = a
        sw.action = #selector(SettingsAction.fire)
        return card(row(words(title, detail), sw))
    }

    func row(_ lead: NSView, _ control: NSView) -> NSView {
        lead.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let gap = NSView()
        gap.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let r = stack([lead, gap, control], vertical: false, spacing: 12)
        r.distribution = .fill
        return r
    }

    func card(_ content: NSView) -> NSView {
        let c = NSView()
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        c.layer?.cornerRadius = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(content)
        NSLayoutConstraint.activate([
            c.widthAnchor.constraint(equalToConstant: SettingsWindow.width),
            content.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: c.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10),
        ])
        return c
    }

    func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = vertical ? .vertical : .horizontal
        s.alignment = vertical ? .leading : .centerY
        s.spacing = spacing
        return s
    }
}
