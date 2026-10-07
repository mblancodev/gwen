// ~/.gwen/config.json — Gwen-only prefs (dictation, capture). translateTo lives in UserDefaults.
import Foundation

enum GwenConfig {
    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gwen")
    }
    static var path: URL { home.appendingPathComponent("config.json") }

    static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaults()
        }
        return defaults().merging(obj) { _, new in new }
    }

    static func defaults() -> [String: Any] {
        ["learn_from_edits": true, "format_dictation": false, "keep_corrected": false,
         "apple_speech": false, "polish": false, "hud_visible": false]
    }

    static func bool(_ key: String) -> Bool {
        (load()[key] as? Bool) ?? (defaults()[key] as? Bool) ?? false
    }

    static func set(_ key: String, _ value: Any) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var cfg = load()
        cfg[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path)
        }
    }
}
