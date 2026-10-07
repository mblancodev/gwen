// Short history of dictation takes → ~/.gwen/voice/takes.json (newest first, capped).
import Foundation

struct Take: Equatable {
    var text: String
    var at: TimeInterval
    var lang: String
}

enum Takes {
    static let maxCount = 25
    static var path: URL {
        GwenConfig.home.appendingPathComponent("voice").appendingPathComponent("takes.json")
    }

    static func load() -> [Take] {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let raw: [[String: Any]]
        if let list = obj as? [[String: Any]] {
            raw = list
        } else if let dict = obj as? [String: Any], let list = dict["takes"] as? [[String: Any]] {
            raw = list
        } else {
            return []
        }
        return raw.compactMap { row in
            guard let text = row["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let at = (row["at"] as? Double) ?? (row["at"] as? Int).map(Double.init) ?? 0
            let lang = row["lang"] as? String ?? ""
            return Take(text: text, at: at, lang: lang)
        }
    }

    static func save(_ takes: [Take]) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows: [[String: Any]] = takes.map { ["text": $0.text, "at": $0.at, "lang": $0.lang] }
        let payload: [String: Any] = ["takes": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let tmp = path.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
            try fm.moveItem(at: tmp, to: path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    @discardableResult
    static func record(_ text: String, lang: String = "") -> [Take] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return load() }
        var all = load()
        let now = Date().timeIntervalSince1970
        if let first = all.first, first.text == t {
            all[0].at = now
            if !lang.isEmpty { all[0].lang = lang }
        } else {
            all.insert(Take(text: t, at: now, lang: lang), at: 0)
            if all.count > maxCount { all = Array(all.prefix(maxCount)) }
        }
        save(all)
        return all
    }

    static var last: Take? { load().first }

    static func clear() { save([]) }
}
