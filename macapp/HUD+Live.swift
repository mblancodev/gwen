// Live words while dictating: recognizer partials via Mic spotter, or stdin `live`.
import AppKit

extension HUD {
    static var live: (task: Int, done: String, last: String)?

    func liveWords(_ s: String) {
        HUD.live = nil
        micFifo.queue.async {
            let spotter = micFifo.spotter
            if s == "dictating" { spotter.useLiveLocale() }
            else { spotter.useWakeLocale() }
            guard s == "dictating", spotter.wanted, spotter.recognizer != nil else { return }
            spotter.restart()
            let id = spotter.id
            DispatchQueue.main.async { [weak self] in
                if self?.state == "dictating" { HUD.live = (id, "", "") }
            }
        }
    }

    func heardLive(_ task: Int, _ text: String) {
        guard var l = HUD.live, task >= l.task, state == "dictating" else { return }
        if task != l.task { l = (task, [l.done, l.last].filter { !$0.isEmpty }.joined(separator: " "), "") }
        l.last = text
        HUD.live = l
        emit("said " + [l.done, l.last].filter { !$0.isEmpty }.joined(separator: " "))
    }

    func showLive(_ text: String) {
        guard state == "dictating" || state == "translating" else { return }
        view.text = HUD.tail(text)
        resizeBarInPlace()
    }

    static func tail(_ text: String, max: Int = 60) -> String {
        guard text.count > max else { return text }
        let end = text.suffix(max)
        return "…" + (end.firstIndex(of: " ").map { end[end.index(after: $0)...] } ?? end)
    }
}
