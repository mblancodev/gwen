// Bar layout helpers and short guide bubbles.
import AppKit

extension HUD {
    /// Grow or shrink the bar without replaying the entrance animation (idle chip, live words).
    func resizeBarInPlace() {
        guard panel.isVisible, !sliding, let screen = barScreen else { return }
        let size = view.preferredSize
        guard abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: barY(size.height), width: size.width, height: size.height),
                       display: true)
    }

    func pushLevel(_ v: CGFloat) {
        view.levels.removeFirst()
        view.levels.append(min(1, max(0.08, v)))
        view.needsDisplay = true
    }

    var barScreen: NSScreen? { NSScreen.screens.first }

    func barY(_ height: CGFloat) -> CGFloat {
        guard let s = barScreen else { return 0 }
        let bottom = s.frame.minY, f = s.visibleFrame
        if docked && idleBar {
            // Peek the restore tab just above the Dock / usable bottom — never under the Dock.
            return f.minY - height + PillView.tabH + 2
        }
        return f.minY - bottom > 8 ? f.minY + 1.5 : bottom + 0.5
    }

    func toggleDock() {
        guard idleBar else { return }
        docked.toggle()
        UserDefaults.standard.set(docked, forKey: "barDocked")
        sliding = true
        apply(state)
    }

    /// The bar reached its place: docking one lands with a sound; the tab rises back out of it.
    /// A timer: `animator()` can't drive `tabRise`, a plain Swift property, so it stayed at 0.
    func barLanded(_ slid: Bool) {
        guard slid else { return }
        if docked && idleBar { NSSound(named: "Bottle")?.play() }
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            let k = min(1, Date().timeIntervalSince(start) / 0.25)
            self?.view.tabRise = CGFloat(k)
            if k >= 1 { t.invalidate() }
        }
    }

    func showGuide(_ text: String, hideAfter: Double? = nil) {
        let size = guide.show(text)
        guard let screen = barScreen else { return }
        let f = screen.visibleFrame
        let x = f.midX - size.width / 2
        let y = panel.isVisible ? panel.frame.maxY + 8 : f.minY + 40
        guidePanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        guidePanel.orderFrontRegardless()
        guideHide?.invalidate()
        if let hideAfter {
            guideHide = Timer.scheduledTimer(withTimeInterval: hideAfter, repeats: false) { [weak self] _ in
                self?.hideGuide()
            }
        }
    }

    func hideGuide() { guidePanel.orderOut(nil) }

    func setHudVisible(_ on: Bool) {
        hudVisibleInCaptures = on
        GwenConfig.set("hud_visible", on)
        applyHudSharing(statusWindow: item.button?.window)
        emit(on ? "visible on" : "visible off")
        SettingsWindow.refresh()
    }
}
