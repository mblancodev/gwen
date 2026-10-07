// Gwen.app: menu bar + bottom pill for dictation and translate.
// Protocol (line-based, Gwen subset):
//   in:  state idle|paused|dictating|cleaning|translating
//        level <0..1>   live <text>   insert <text>   dictated <text>
//        transcript <text>   learned [word]   chip <label>   translate <lang>
//        stt up|down   visible on|off   guide <text>   oneline-apps <ids>
//   out: dictate hold|release|free|end|cancel   cancel   pause|resume   quit
//        compose fixed <json>   visible on|off   input <mic name|default>   ready
// Also: gwen://ping|dictate|translate from other apps (HUD+URL.swift).
// Build: swiftc -O macapp/*.swift -o dist/Gwen.app/Contents/MacOS/Gwen
import AppKit
import Darwin

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// Started by `gwen listen`, macOS charges Gwen's permission requests to whatever ran the listener (a terminal, an
/// editor): one without a speech-recognition usage string gets Gwen killed on the spot. Re-exec in place (same pid,
/// same pipes) disclaiming that parent, so Microphone / Speech / Accessibility are Gwen.app's own.
func ownPermissions() {
    guard getenv("GWEN_OWN_TCC") == nil, let path = Bundle.main.executablePath else { return }
    setenv("GWEN_OWN_TCC", "1", 1)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
    _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
    var argv = CommandLine.arguments.map { strdup($0) } + [nil]
    posix_spawn(nil, path, nil, &attr, &argv, environ)  // returns only if it failed: carry on as we are
}
/// `--run <program> <args…>`: the login item (`gwen install`). launchd starts Gwen.app so macOS lists the background
/// item as "Gwen", not "python3"; this process then becomes the listener, which brings up its own Gwen.app as ever.
if let i = CommandLine.arguments.firstIndex(of: "--run"), i + 1 < CommandLine.arguments.count {
    var argv = CommandLine.arguments[(i + 1)...].map { strdup($0) } + [nil]
    execv(argv[0]!, &argv)  // returns only if it failed: carry on as a bare bar
}
ownPermissions()

setvbuf(stdout, nil, _IOLBF, 0)

/// True when `gwen listen` (or another parent) attached a pipe — EOF then means quit.
/// Finder / `open` give /dev/null; quitting on that empty read made the app look like it crashed.
func stdinIsListenerPipe() -> Bool {
    var info = stat()
    guard fstat(STDIN_FILENO, &info) == 0 else { return false }
    let mode = info.st_mode & S_IFMT
    return mode == S_IFIFO || mode == S_IFSOCK
}

if CommandLine.arguments.contains("--transcribe") { Transcribe.run(CommandLine.arguments) }
if CommandLine.arguments.contains("--settings") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let hud = HUD()
    if CommandLine.arguments.contains("--tone") {
        UserDefaults.standard.set(SettingsWindow.Section.tone.rawValue, forKey: SettingsWindow.sectionKey)
    }
    SettingsWindow.show(hud)
    app.run()
}

startListenerIfOrphan()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let hud = HUD()
hud.serveURLs()

let quitOnStdinEOF = stdinIsListenerPipe()
var input = FileHandle.standardInput
DispatchQueue.global().async {
    var buffer = Data()
    while true {
        let chunk = input.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            DispatchQueue.main.async { hud.handle(line) }
        }
    }
    if quitOnStdinEOF {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

Keys.install()
HUD.restoreSoundOnExit()
emit("ready")
app.run()
