// Per-app dictation tone → ~/.gwen/voice/tone.json (mirrors gwen/voice/tone.py).
import AppKit

enum ToneKind: String, CaseIterable {
    case `default`, casual, formal, verbatim
    var title: String {
        switch self {
        case .default: return "Default"
        case .casual: return "Casual"
        case .formal: return "Formal"
        case .verbatim: return "Verbatim"
        }
    }
    var blurb: String {
        switch self {
        case .default: return "Usual cleanup"
        case .casual: return "Chatty — short lines drop the trailing period"
        case .formal: return "Expands contractions; finishes the sentence"
        case .verbatim: return "Keeps wording — tidy only (terminals)"
        }
    }
}

enum Tone {
    static let defaults: [String: ToneKind] = [
        "com.tinyspeck.slackdesktop": .casual,
        "com.apple.MobileSMS": .casual,
        "com.apple.iChat": .casual,
        "com.hnc.Discord": .casual,
        "net.whatsapp.WhatsApp": .casual,
        "com.apple.FaceTime": .casual,
        "com.facebook.archon": .casual,
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        "com.readdle.smartemail-Mac": .formal,
        "com.apple.mobilemail": .formal,
        "com.apple.Terminal": .verbatim,
        "com.googlecode.iterm2": .verbatim,
        "dev.warp.Warp-Stable": .verbatim,
        "dev.warp.Warp": .verbatim,
        "com.mitchellh.ghostty": .verbatim,
        "net.kovidgoyal.kitty": .verbatim,
        "org.alacritty": .verbatim,
        "io.alacritty": .verbatim,
        "com.github.wez.wezterm": .verbatim,
        "co.zeit.hyper": .verbatim,
        "org.tabby": .verbatim,
        "com.termius-dmg.mac": .verbatim,
    ]

    static var path: URL {
        GwenConfig.home.appendingPathComponent("voice").appendingPathComponent("tone.json")
    }

    static func isBuiltIn(_ bundle: String) -> Bool { defaults[bundle] != nil }

    static func loadOverrides() -> [String: ToneKind] {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = obj["apps"] as? [String: String] else { return [:] }
        var out: [String: ToneKind] = [:]
        for (k, v) in apps {
            if let t = ToneKind(rawValue: v) { out[k] = t }
        }
        return out
    }

    static func saveOverrides(_ apps: [String: ToneKind]) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rows: [String: String] = [:]
        for (k, v) in apps { rows[k] = v.rawValue }
        let payload: [String: Any] = ["apps": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    static func resolve(_ bundle: String) -> ToneKind {
        let o = loadOverrides()
        if let t = o[bundle] { return t }
        return defaults[bundle] ?? .default
    }

    /// Persist a tone. Built-in apps matching their default drop the override; custom apps always stay listed.
    static func set(_ bundle: String, _ tone: ToneKind) {
        var o = loadOverrides()
        if let builtIn = defaults[bundle], tone == builtIn {
            o.removeValue(forKey: bundle)
        } else {
            o[bundle] = tone
        }
        saveOverrides(o)
    }

    /// Remove a custom app, or reset a built-in override to its shipped tone.
    static func remove(_ bundle: String) {
        var o = loadOverrides()
        o.removeValue(forKey: bundle)
        saveOverrides(o)
    }

    static func clear(_ bundle: String) { remove(bundle) }

    /// Bundles to show in Settings: defaults ∪ overrides, sorted by tone then title.
    static func listed() -> [(bundle: String, tone: ToneKind, overridden: Bool, custom: Bool)] {
        let o = loadOverrides()
        let keys = Set(defaults.keys).union(o.keys).sorted {
            let a = resolve($0), b = resolve($1)
            if a != b { return a.rawValue < b.rawValue }
            return appTitle($0).localizedCaseInsensitiveCompare(appTitle($1)) == .orderedAscending
        }
        return keys.map { b in
            (b, resolve(b), o[b] != nil, !isBuiltIn(b))
        }
    }

    static func appTitle(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
           let b = Bundle(url: url),
           let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String),
           !name.isEmpty {
            return name
        }
        return bundle.split(separator: ".").last.map(String.init) ?? bundle
    }
}
