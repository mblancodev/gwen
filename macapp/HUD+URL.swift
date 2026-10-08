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
/// Without it, a Gwen.app from the DMG installs itself; anything else (or from a terminal: `gwen hud`, mocks)
/// carries on as a bare bar.
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
    installFromBundle()
}

/// `gwen bundle` puts Gwen's Python in Contents/Resources/gwen. First open of that copy: run its `gwen install`,
/// which registers the login listener and starts it, and the listener brings up its own Gwen.app.
private func installFromBundle() {
    let path = Bundle.main.bundlePath, cli = path + "/Contents/Resources/gwen/bin/gwen"
    guard FileManager.default.fileExists(atPath: cli) else { return }
    func tell(_ title: String, _ text: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
    // The login item would point at the disk image (or the read-only copy macOS runs a quarantined app from).
    guard !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") else {
        tell("Move Gwen to Applications first", "Drag Gwen into the Applications folder, then open it from there.")
        exit(0)
    }
    tell("Setting up Gwen", "The first run downloads the speech model, which takes a few minutes. "
         + "The bar appears at the bottom of the screen when Gwen is ready.")
    let logs = NSHomeDirectory() + "/.gwen/logs", log = logs + "/install.log"
    try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log, contents: nil)
    let p = Process()
    // ponytail: the Mac's own python3, which only exists with Apple's command line tools; embed a Python in the
    // app when asking for those is too much.
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-B", cli, "install"]  // -B: a __pycache__ inside Gwen.app breaks its signature
    var env = ProcessInfo.processInfo.environment  // Finder's PATH has no Homebrew
    env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    p.environment = env
    p.standardOutput = FileHandle(forWritingAtPath: log)
    p.standardError = p.standardOutput
    let ran = (try? p.run()) != nil
    if ran { p.waitUntilExit() }
    guard ran, p.terminationStatus == 0 else {
        tell("Gwen couldn't finish setting up", "It needs Apple's command line tools: run xcode-select --install in "
             + "Terminal, then open Gwen again. Details are in ~/.gwen/logs/install.log.")
        exit(1)
    }
    exit(0)
}
