// Status words for the menu bar / VoiceOver.
import AppKit

enum Status {
    static let listening = "Listening", running = "Running", done = "Done"
    static let hud = ["idle": listening, "paused": listening, "dictating": listening,
                      "cleaning": running, "translating": running, "transcript": done]

    static func menuLine(state: String) -> String {
        let w = hud[state] ?? listening
        return state == "paused" ? w + " · microphone off" : w
    }
}
