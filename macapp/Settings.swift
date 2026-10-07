// Gwen Settings: Dictation, Language, Tone, Shortcuts, Capture. Black Setup-styled window.
import AppKit

final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Section: String, CaseIterable {
        case dictation, translate, tone, shortcuts, capture
        var title: String {
            ["dictation": "Dictation", "translate": "Language", "tone": "Tone", "shortcuts": "Shortcuts",
             "capture": "Capture"][rawValue] ?? rawValue
        }
        var symbol: String {
            ["dictation": "waveform", "translate": "globe", "tone": "text.bubble", "shortcuts": "keyboard",
             "capture": "camera"][rawValue] ?? "circle"
        }
    }

    static var shared: SettingsWindow?
    static let sectionKey = "gwenSettingsSection"
    static let side: CGFloat = 160, width: CGFloat = 420, inset: CGFloat = 24

    static func show(_ hud: HUD?) {
        let s = shared ?? SettingsWindow(hud)
        shared = s
        s.open()
    }

    static func refresh() {
        guard let s = shared, s.window.isVisible else { return }
        s.rebuild()
    }

    weak var hud: HUD?
    let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: side + width + 2 * inset, height: 440),
                               styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
    let sidebar = NSStackView()
    let page = NSStackView()
    let scroll = NSScrollView()
    var tabs: [Section: SidebarButton] = [:]
    var section: Section
    var sideActions: [SettingsAction] = []
    var actions: [SettingsAction] = []
    var returnTo: NSRunningApplication?

    init(_ hud: HUD?) {
        self.hud = hud
        section = Section(rawValue: UserDefaults.standard.string(forKey: SettingsWindow.sectionKey) ?? "") ?? .dictation
        super.init()
        window.title = "Gwen Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        build()
        window.center()
        window.setFrameAutosaveName("GwenSettings")
    }

    func open() {
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            returnTo = front?.processIdentifier == NSRunningApplication.current.processIdentifier ? nil : front
        }
        select(section)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        actions.removeAll()
        page.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let back = returnTo
        returnTo = nil
        DispatchQueue.main.async {
            guard NSRunningApplication.current.isActive, let back, !back.isTerminated,
                  back.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
            back.activate()
        }
    }

    func rebuild() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.select(self.section)
        }
    }

    func select(_ s: Section) {
        section = s
        UserDefaults.standard.set(s.rawValue, forKey: SettingsWindow.sectionKey)
        tabs.forEach { $0.value.selected = $0.key == s }
        actions.removeAll()
        page.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views(for: s).forEach(page.addArrangedSubview)
        window.recalculateKeyViewLoop()
    }

    func build() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        let side = NSView()
        side.wantsLayer = true
        side.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 48, left: 10, bottom: 16, right: 10)
        for s in Section.allCases {
            let b = SidebarButton(s.title, symbol: s.symbol)
            let a = SettingsAction { [weak self] in self?.select(s) }
            sideActions.append(a)
            b.target = a
            b.action = #selector(SettingsAction.fire)
            tabs[s] = b
            sidebar.addArrangedSubview(b)
            b.widthAnchor.constraint(equalToConstant: SettingsWindow.side - 20).isActive = true
        }
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 12
        page.edgeInsets = NSEdgeInsets(top: 44, left: SettingsWindow.inset, bottom: 24, right: SettingsWindow.inset)
        let doc = FlippedView()
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        for v in [side, sidebar, scroll, doc, page] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        doc.addSubview(page)
        side.addSubview(sidebar)
        root.addSubview(side)
        root.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor), side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor), side.widthAnchor.constraint(equalToConstant: SettingsWindow.side),
            sidebar.leadingAnchor.constraint(equalTo: side.leadingAnchor), sidebar.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: side.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: side.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor), doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            page.leadingAnchor.constraint(equalTo: doc.leadingAnchor), page.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            page.topAnchor.constraint(equalTo: doc.topAnchor), page.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        window.contentView = root
    }
}

final class SettingsPanel: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command && event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsAction: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class SidebarButton: NSButton {
    var selected = false { didSet { paint(); setAccessibilityValue(selected ? 1 : 0) } }

    init(_ name: String, symbol: String) {
        super.init(frame: .zero)
        cell = SidebarCell()
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        image = SidebarButton.icon(symbol)
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        contentTintColor = .secondaryLabelColor
        attributedTitle = NSAttributedString(string: "  " + name, attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                                               .foregroundColor: NSColor.labelColor])
        setAccessibilityLabel(name)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { nil }

    static func icon(_ symbol: String) -> NSImage? {
        guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let tile = NSSize(width: 20, height: 18)
        let img = NSImage(size: tile, flipped: false) { r in
            let s = sym.size
            sym.draw(in: NSRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height))
            return true
        }
        img.isTemplate = true
        return img
    }

    override var isHighlighted: Bool { didSet { paint() } }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 16, height: 28) }

    private func paint() {
        let a: CGFloat = selected ? 0.14 : isHighlighted ? 0.08 : 0
        layer?.backgroundColor = NSColor(white: 1, alpha: a).cgColor
        contentTintColor = selected ? .labelColor : .secondaryLabelColor
    }
}

final class SidebarCell: NSButtonCell {
    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        super.drawInterior(withFrame: NSRect(x: frame.minX + 10, y: frame.minY, width: frame.width - 10, height: frame.height), in: view)
    }
}

final class PillButton: NSButton {
    private let primary: Bool
    init(_ name: String, target: AnyObject, action: Selector, primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 15
        attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white])
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        paint()
    }
    required init?(coder: NSCoder) { nil }
    override var isHighlighted: Bool { didSet { paint() } }
    private func paint() {
        layer?.backgroundColor = NSColor(white: 1, alpha: primary ? (isHighlighted ? 0.28 : 0.22) : (isHighlighted ? 0.16 : 0.1)).cgColor
    }
}
