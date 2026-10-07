// On-device translation (Apple Translation, macOS 15+).
import AppKit
import Carbon
import NaturalLanguage
import SwiftUI
import Translation

let LANGS: [(code: String, name: String)] = [
    ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("it", "Italian"), ("pt", "Portuguese"), ("de", "German"),
]

/// Prefer one of Gwen's six languages so a short Spanish phrase is not misread as Swedish (etc.).
func spokenLanguage(_ text: String) -> String? {
    let r = NLLanguageRecognizer()
    r.languageConstraints = LANGS.map { NLLanguage(rawValue: $0.code) }
    r.processString(text)
    if let code = r.dominantLanguage?.rawValue { return code }
    return NLLanguageRecognizer.dominantLanguage(for: text).flatMap { supportedLanguage($0.rawValue) }
}

func sameLanguage(_ a: String, _ b: String) -> Bool {
    Locale.Language(identifier: a).languageCode == Locale.Language(identifier: b).languageCode
}

func supportedLanguage(_ code: String) -> String? {
    guard Locale.Language(identifier: code).languageCode != nil else { return nil }
    return LANGS.first { sameLanguage($0.code, code) }?.code
}

func languageName(_ code: String) -> String { LANGS.first { sameLanguage($0.code, code) }?.name ?? code }

func translateChoice() -> String {
    guard let raw = UserDefaults.standard.string(forKey: "translateTo") else { return "mac" }
    if raw == "mac" || raw == "keyboard" { return raw }
    return supportedLanguage(raw) == nil ? "mac" : raw
}

func resolveTranslate(_ choice: String) -> String {
    if choice == "keyboard", let code = keyboardLanguage().flatMap(supportedLanguage) { return code }
    if let code = supportedLanguage(choice) { return code }
    return Locale.preferredLanguages.first.flatMap(supportedLanguage) ?? "en"
}

func translateChoices() -> [(title: String, value: String)] {
    let mac = "Mac language (\(languageName(resolveTranslate("mac"))))"
    let key = keyboardLanguage().flatMap(supportedLanguage).map { "Keyboard language (\(languageName($0)))" } ?? "Keyboard language"
    return [(mac, "mac"), (key, "keyboard")] + LANGS.map { ($0.name, $0.code) }
}

/// The Text Input Source calls trap off the main thread, and the mic queue asks too (WakeSpotter.liveLocaleId).
func keyboardLanguage() -> String? {
    guard Thread.isMainThread else { return DispatchQueue.main.sync { keyboardLanguage() } }
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
    return (Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as NSArray).firstObject as? String
}

enum TranslateOutcome {
    case translated(String)
    case unchanged
    case failed
}

final class Translator {
    private var job: Any?
    private let panel = floatingPanel(NSSize(width: 1, height: 1))
    private var seq = 0

    /// `unchanged` = already that language; `failed` = error (not a silent original).
    /// A newer call supersedes an in-flight one: the old callback is not invoked.
    func translate(_ text: String, to target: String, done: @escaping (TranslateOutcome) -> Void) {
        guard !target.isEmpty else { return done(.unchanged) }
        guard let source = spokenLanguage(text) else {
            FileHandle.standardError.write("translate: no source language\n".data(using: .utf8)!)
            return done(.failed)
        }
        if sameLanguage(source, target) {
            FileHandle.standardError.write("translate: same-lang (\(source)→\(target))\n".data(using: .utf8)!)
            return done(.unchanged)
        }
        guard #available(macOS 15, *) else { return done(.failed) }
        seq += 1
        let my = seq
        var finished = false
        let finish = { (outcome: TranslateOutcome) in
            guard my == self.seq, !finished else { return }
            finished = true
            done(outcome)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard my == self.seq, !finished else { return }
            FileHandle.standardError.write("translate: timed out (\(source)→\(target))\n".data(using: .utf8)!)
            finish(.failed)
        }
        if job == nil {
            let j = TranslationJob()
            panel.alphaValue = 0
            panel.contentView = NSHostingView(rootView: TranslationHost(job: j))
            panel.orderFrontRegardless()
            job = j
        }
        (job as! TranslationJob).run(text, from: source, to: target) { result in
            DispatchQueue.main.async {
                guard my == self.seq else {
                    FileHandle.standardError.write("translate: cancelled ignored (superseded)\n".data(using: .utf8)!)
                    return
                }
                switch result {
                case .success(let out):
                    finish(.translated(out))
                case .failure(let err):
                    if err is CancellationError {
                        FileHandle.standardError.write("translate: cancelled ignored (session)\n".data(using: .utf8)!)
                        return
                    }
                    FileHandle.standardError.write("translate: failed (\(err))\n".data(using: .utf8)!)
                    finish(.failed)
                }
            }
        }
    }
}

@available(macOS 15, *)
final class TranslationJob: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    var text = ""
    var gen = 0
    var done: ((Result<String, Error>) -> Void)?

    func run(_ text: String, from source: String, to target: String, done: @escaping (Result<String, Error>) -> Void) {
        gen += 1
        self.text = text
        self.done = done
        let src = Locale.Language(identifier: source), dst = Locale.Language(identifier: target)
        // invalidate() cancels the in-flight session (NSCocoaErrorDomain 3072); leave that cancel for the re-run.
        if config?.source == src && config?.target == dst {
            config?.invalidate()
        } else {
            config = .init(source: src, target: dst)
        }
    }
}

@available(macOS 15, *)
struct TranslationHost: View {
    @ObservedObject var job: TranslationJob
    var body: some View {
        Color.clear.frame(width: 1, height: 1).translationTask(job.config) { session in
            let gen = job.gen
            let text = job.text
            do {
                let out = try await session.translate(text).targetText
                guard gen == job.gen else { return }
                let done = job.done
                job.done = nil
                done?(.success(out))
            } catch is CancellationError {
                FileHandle.standardError.write("translation cancelled (re-run)\n".data(using: .utf8)!)
            } catch {
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && ns.code == 3072 {
                    FileHandle.standardError.write("translation cancelled (cocoa, left pending)\n".data(using: .utf8)!)
                    return
                }
                FileHandle.standardError.write("translation failed: \(error)\n".data(using: .utf8)!)
                guard gen == job.gen else { return }
                let done = job.done
                job.done = nil
                done?(.failure(error))
            }
        }
    }
}
