// gwen:// — the local API other apps call. Gwen owns the mic and the paste; a caller only asks.
//   gwen://ping                             nothing to do: being delivered is the answer
//   gwen://dictate?mode=hold|free           start dictating; asked again while dictating, finish and paste
//   gwen://translate?mode=selection|speech  same as tap ⌃⇧ / hold ⌃ + ⇧⇧
import AppKit

extension HUD {
    func serveURLs() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: text), url.scheme == "gwen" else { return }
        let mode = url.queryItems?.first { $0.name == "mode" }?.value ?? ""
        switch url.host {
        case "dictate":
            // A URL has no key release: the second call is the release, for hold and hands-free alike.
            if state == "dictating" { emit("dictate end") }
            else if state == "idle" { emit(mode == "free" ? "dictate free" : "dictate hold") }
        case "translate":
            if speechTranslate { finishSpeechTranslate() }
            else if mode == "speech" { beginSpeechTranslate() }
            else { translateSelection(to: "") }
        default: break  // ping
        }
    }
}

/// Opened from Finder, Spotlight or a gwen:// link there is no listener behind the bar, so no mic and no paste.
/// With `gwen install` done, start the login listener and step aside: it brings up its own Gwen.app.
/// Without it (or from a terminal: `gwen hud`, mocks) carry on as a bare bar.
func startListenerIfOrphan() {
    guard !stdinIsListenerPipe(), isatty(STDIN_FILENO) == 0 else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "gui/\(getuid())/app.gwen.listen"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    p.waitUntilExit()
    if p.terminationStatus == 0 { exit(0) }
}
