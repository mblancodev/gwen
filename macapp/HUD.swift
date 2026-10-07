// Gwen HUD: menu bar + bottom pill. Gwen states only (no jobs / compose / Pinns).
import AppKit

final class HUD: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let panel = floatingPanel(NSSize(width: 150, height: 38))
    let view = PillView()
    let statusLine = NSMenuItem(title: "Listening", action: nil, keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "Pause microphone", action: #selector(togglePause), keyEquivalent: "")
    let translateItem = NSMenuItem(title: "Translate last transcript", action: nil, keyEquivalent: "")
    let pasteAgainItem = NSMenuItem(title: "Paste last again", action: #selector(menuPasteLastAgain), keyEquivalent: "v")
    let recentTakesItem = NSMenuItem(title: "Recent takes", action: nil, keyEquivalent: "")
    static let translateToItem = NSMenuItem(title: "Translate to", action: nil, keyEquivalent: "")
    let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    let quitItem = NSMenuItem(title: "Quit Gwen", action: #selector(quit), keyEquivalent: "q")
    var state = "idle"
    var original = ""
    var shownLang = ""
    var pasted = false
    var acceptInsert = true
    var dictationPid: pid_t = 0
    var dictationFocus: AXUIElement?
    let translator = Translator()
    var waveTimer: Timer?
    var hoverTimer: Timer?
    var hiding = false
    var docked = UserDefaults.standard.bool(forKey: "barDocked")
    var sliding = false
    var cursorOnBar = false
    var closing = false
    let hintPanel = floatingPanel(NSSize(width: 150, height: 28))
    let hint = HintView(frame: .zero)
    let guidePanel = floatingPanel(NSSize(width: 280, height: 40))
    let guide = HintView(frame: .zero)
    var guideHide: Timer?
    var transcriptHideTimer: Timer?
    var oneLineApps: Set<String> = []

    override init() {
        super.init()
        hudVisibleInCaptures = GwenConfig.bool("hud_visible")
        let menu = NSMenu()
        statusLine.isEnabled = false
        translateItem.isHidden = true
        pasteAgainItem.keyEquivalentModifierMask = [.control, .command]
        for m in [statusLine, .separator(), pauseItem, HUD.micItem, HUD.translateToItem, translateItem,
                  pasteAgainItem, recentTakesItem, .separator(),
                  settingsItem, .separator(), quitItem] {
            m.target = self
            if m.keyEquivalent == "," || m.keyEquivalent == "q" { m.keyEquivalentModifierMask = .command }
            menu.addItem(m)
        }
        menu.delegate = self
        item.menu = menu
        panel.hasShadow = true
        panel.contentView = view
        panel.ignoresMouseEvents = false
        hintPanel.contentView = hint
        guidePanel.contentView = guide
        view.onHint = { [weak self] on in self?.showHint(on) }
        view.onBar = { [weak self] on in self?.cursorOnBar = on }
        view.onChip = { [weak self] in self?.chipClicked() }
        view.onTranscript = { [weak self] in self?.pasteLastAgain() }
        micFifo.spotter.onHeard = { [weak self] task, text in self?.heardLive(task, text) }
        view.onTab = { [weak self] in self?.toggleDock() }
        watchClipboard()
        apply("idle")
    }

    @objc func togglePause() { emit(state == "paused" ? "resume" : "pause") }
    @objc func openSettings() { SettingsWindow.show(self) }
    @objc func quit() { emit("quit"); exit(0) }

    var idleBar: Bool { state == "idle" }
    var guideShowing: Bool { guidePanel.isVisible }

    func cancelBar() -> Bool {
        guard !["idle", "paused"].contains(state) else { return false }
        if speechTranslate { cancelSpeechTranslate(); return true }
        // Wait-for-selection: Esc / ⌃ may cancel. An in-flight selection translate must keep "Translating…".
        if state == "translating" {
            if translateWaitingForSelection {
                acceptInsert = false
                emit("cancel")
                closing = true
                apply("idle")
                return true
            }
            if selectionTranslateInFlight {
                FileHandle.standardError.write("translate: cancel ignored (in flight)\n".data(using: .utf8)!)
                return false
            }
        }
        acceptInsert = false
        emit("cancel")
        closing = true
        apply("idle")
        return true
    }

    func apply(_ s: String, text: String = "") {
        defer { closing = false }
        if s != "idle" && s != "paused" {
            hoverTimer?.invalidate()
            hiding = false
        }
        if s != "transcript" { transcriptHideTimer?.invalidate(); transcriptHideTimer = nil }
        if s == "dictating" {
            rememberDictationTarget(); acceptInsert = true
            view.chip = chipLabel(translateTarget)
            view.hintNote = Keys.handsFree
                ? "Stops when you stop talking · tap ⌃ to cancel · tap the language to change it" : ""
        } else if state == "dictating" {
            view.hintNote = ""
            if s == "cleaning" { view.chip = "" }
        }
        if s == "idle" {
            view.chip = chipLabel(translateTarget)  // darkened idle bar: same Translate-to chip as while dictating
        } else if s == "paused" {
            view.chip = ""
        }
        let was = state
        state = s
        if s != was { liveWords(s) }
        updateMute()
        if s != "translating" { stopWaitingForSelection() }
        if s != "idle" && s != "paused" || idleBar {
            view.mode = s
            if !text.isEmpty || view.text.isEmpty || s != "dictating" { view.text = text }
            if s == "dictating" && text.isEmpty && was != "dictating" { view.text = "" }
        }
        let symbol = ["paused": "mic.slash", "idle": "waveform"][s] ?? "waveform.circle.fill"
        // Menu-bar size: unconfigured SF Symbols read large in the menu bar; pin like a template status icon.
        let conf = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(conf)
        img?.isTemplate = true
        img?.size = NSSize(width: 16, height: 16)
        item.button?.image = img
        item.button?.window?.sharingType = hudSharingType()
        statusLine.title = Status.menuLine(state: s)
        pauseItem.title = s == "paused" ? "Resume microphone" : "Pause microphone"
        item.button?.setAccessibilityLabel("Gwen. " + statusLine.title + ".")
        guard let screen = barScreen else { return }
        let f = screen.visibleFrame
        waveTimer?.invalidate()
        if ["cleaning", "translating"].contains(s) && !reduceMotion {
            waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.view.phase += 0.12
                self?.view.needsDisplay = true
            }
        }
        let resting = s == "idle" || s == "paused"
        let visible = !resting || idleBar
        view.tab = idleBar
        view.tabUp = docked
        let size = view.preferredSize
        let frame = NSRect(x: f.midX - size.width / 2, y: barY(size.height), width: size.width, height: size.height)
        if visible {
            hiding = false
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.setFrame(frame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -10), display: true)
                panel.orderFrontRegardless()
            }
            let slid = sliding
            sliding = false
            if slid { view.tabRise = 0 }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = slid ? 0.45 : 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = sttDown ? 0.5 : 1
            }, completionHandler: { [weak self] in self?.barLanded(slid) })
        } else if panel.isVisible {
            hideBar()
        }
    }

    func hideBar() {
        hoverTimer?.invalidate()
        if hiding { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduceMotion ? 0.01 : 0.4
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -16), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.hiding = false
            guard (self.state == "idle" && !self.idleBar) || self.state == "paused" else {
                self.panel.alphaValue = sttDown ? 0.5 : 1
                return
            }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }

    func showHint(_ on: Bool) {
        guard on, panel.isVisible, !view.hint.isEmpty else { hintPanel.orderOut(nil); return }
        let size = hint.show(view.hint)
        let x = panel.frame.minX + view.infoRect.midX - size.width / 2
        hintPanel.setFrame(NSRect(x: x, y: panel.frame.maxY + 6, width: size.width, height: size.height), display: true)
        hintPanel.orderFrontRegardless()
    }

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "state": applyState(arg)
        case "level": pushLevel(CGFloat(Double(arg) ?? 0))
        case "live": showLive(arg)
        case "learned":
            if arg.isEmpty { showGuide("Learned a correction.", hideAfter: 5) }
            else { showGuide("I'll write \(arg) from now on.", hideAfter: 5) }
        case "insert": transcribed(lineBreaks(arg))
        case "dictated": transcribed(lineBreaks(arg), watch: true)
        case "oneline-apps":
            oneLineApps = Set(arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        case "transcript":
            view.chip = ""
            showCopiedTranscript(lineBreaks(arg))
        case "stt":
            sttDown = arg == "down"
            if panel.isVisible { panel.alphaValue = sttDown ? 0.5 : 1 }
            view.needsDisplay = true
        case "chip":
            view.chip = arg
            if panel.isVisible { apply(state, text: view.text) }
        case "translate": translateSelection(to: arg)
        case "visible":
            hudVisibleInCaptures = arg == "on"
            GwenConfig.set("hud_visible", hudVisibleInCaptures)
            applyHudSharing(statusWindow: item.button?.window)
            SettingsWindow.refresh()
        case "mic": micFifo.handle(arg)
        case "guide": showGuide(arg, hideAfter: 6)
        default: break
        }
    }
}

extension HUD: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        translateItem.isHidden = original.isEmpty
        translateItem.submenu = original.isEmpty ? nil : langMenu()
        pasteAgainItem.isEnabled = Takes.last != nil
        recentTakesItem.submenu = recentTakesMenu()
        fillMicMenu()
        if #available(macOS 15, *) { HUD.translateToItem.isHidden = false }
        else { HUD.translateToItem.isHidden = true }
        HUD.translateToItem.submenu = translateToMenu()
    }
}
