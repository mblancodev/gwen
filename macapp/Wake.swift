// "Hey Gwen" in your voice: what the recognizer writes when you say it → ~/.gwen/voice/wake.json (gwen/voice/wake.py
// matches those too), and the window that teaches it: once on first run, again from Settings.
import AppKit

final class WakeTrainer: NSObject, NSWindowDelegate {
    static var shared: WakeTrainer?
    static let rounds = 3
    static var file: URL { GwenConfig.home.appendingPathComponent("voice").appendingPathComponent("wake.json") }

    static func phrases() -> [String] {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return obj["phrases"] as? [String] ?? []
    }

    static func show() {
        if shared == nil { shared = WakeTrainer() }
        shared?.begin()
    }

    /// Once per Mac, the first time the mic and the recognizer are both up (mocks never open the mic).
    static func firstRun() {
        guard !UserDefaults.standard.bool(forKey: "wakeTaught") else { return }
        UserDefaults.standard.set(true, forKey: "wakeTaught")
        show()
    }

    static func heard(_ task: Int, _ text: String) { shared?.take(task, text) }

    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 230),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let heardLabel = NSTextField(labelWithString: "")
    lazy var button = PillButton("Skip", target: self, action: #selector(close), primary: true)
    var samples: [String] = []
    var current = ""
    var after = Int.max  // partials from tasks up to this one belong to an earlier round
    var settle: Timer?
    var active = false

    override init() {
        super.init()
        window.title = "Hey Gwen"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        detail.font = NSFont.systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320
        heardLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        heardLabel.lineBreakMode = .byTruncatingHead
        let stack = NSStackView(views: [title, detail, heardLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 30, bottom: 24, right: 30)
        window.contentView = stack
    }

    func begin() {
        samples = []
        active = true
        emit("wake off")  // saying it here must not start a dictation
        fresh()
        render()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// A new recognizer task, so each round's transcript starts empty.
    func fresh() {
        current = ""
        after = .max
        micFifo.queue.async {
            let spotter = micFifo.spotter
            if spotter.wanted { spotter.useWakeLocale(); spotter.restart() }
            let id = spotter.id
            DispatchQueue.main.async { [weak self] in self?.after = id - 1 }
        }
    }

    func render(_ nudge: String = "") {
        title.stringValue = "Say “Hey Gwen”"
        detail.stringValue = "Say it \(WakeTrainer.rounds) times, the way you normally would. Gwen learns how it sounds in "
            + "your voice, then you can say it any time to dictate hands-free. Nothing showing below? Check the "
            + "Microphone in Gwen's menu."
        heardLabel.stringValue = nudge.isEmpty ? "\(samples.count + 1) of \(WakeTrainer.rounds) · listening…" : nudge
        button.title = "Skip"
    }

    func take(_ task: Int, _ text: String) {
        guard active, task > after else { return }
        current = text
        heardLabel.stringValue = "“\(text)”"
        settle?.invalidate()
        settle = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in self?.keep() }
    }

    func keep() {
        let words = current.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        // ponytail: 2–4 words is the only guard against learning something you say all day; add a review-and-delete
        // list in Settings if a learned phrase starts dictations by accident.
        let ok = (2...4).contains(words.count)
        if ok { samples.append(words.joined(separator: " ")) }
        if samples.count >= WakeTrainer.rounds { return finish() }
        fresh()
        render(ok ? "" : "Just the two words: “Hey Gwen”")
    }

    func finish() {
        active = false
        let phrases = Array(Set(samples)).sorted()  // a retrain replaces what was learned before
        try? FileManager.default.createDirectory(at: WakeTrainer.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: ["phrases": phrases], options: [.prettyPrinted]) {
            try? data.write(to: WakeTrainer.file)
        }
        title.stringValue = "Got it"
        detail.stringValue = "Say “Hey Gwen”, then talk. Gwen pastes when you stop. You can retrain in Settings → Dictation."
        heardLabel.stringValue = phrases.joined(separator: " · ")
        button.title = "Done"
        resume()
        SettingsWindow.refresh()
    }

    func resume() { emit(GwenConfig.bool("wake") ? "wake on" : "wake off") }

    @objc func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        settle?.invalidate()
        if active { active = false; resume() }
    }
}
