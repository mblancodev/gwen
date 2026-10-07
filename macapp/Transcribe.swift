// `Gwen --transcribe <wav> [--locale en]`: Apple SpeechAnalyzer (macOS 26+), no UI.
import AVFoundation
import Speech

enum Transcribe {
    static func run(_ args: [String]) -> Never {
        guard #available(macOS 26, *) else { finish(["error": "speech to text needs macOS 26"]) }
        guard let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count else { finish(["error": "no recording"]) }
        let url = URL(fileURLWithPath: args[i + 1])
        let asked = args.firstIndex(of: "--locale").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        Task {
            do {
                var best: Heard?
                for locale in await locales(asked) {
                    let got = try await hear(url, locale)
                    if best == nil || got.confidence > best!.confidence { best = got }
                }
                guard let best else { finish(["error": "no speech model for \(asked ?? "this Mac's languages")"]) }
                finish(["text": best.text, "language": best.language, "words": best.words])
            } catch {
                finish(["error": "\(error)"])
            }
        }
        dispatchMain()
    }

    static func finish(_ reply: [String: Any]) -> Never {
        print(String(decoding: try! JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        exit(reply["error"] == nil ? 0 : 1)
    }

    struct Heard {
        var text = "", language = "", words: [[String: Any]] = [], confidence = 0.0
    }

    @available(macOS 26, *)
    static func locales(_ asked: String?) async -> [Locale] {
        let mine = Locale.preferredLanguages
        let wanted = asked.map { code in [mine.first { $0.hasPrefix(code) } ?? code] } ?? mine
        var found: [Locale] = []
        for id in wanted {
            guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)),
                  !found.contains(where: { $0.language.languageCode == l.language.languageCode }) else { continue }
            found.append(l)
        }
        return Array(found.prefix(2))
    }

    @available(macOS 26, *)
    static func hear(_ url: URL, _ locale: Locale) async throws -> Heard {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () -> Heard in
            var heard = Heard(language: locale.language.languageCode?.identifier ?? "")
            var scores: [Double] = []
            for try await result in transcriber.results {
                heard.text += String(result.text.characters)
                for run in result.text.runs {
                    let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty, let time = run.audioTimeRange else { continue }
                    heard.words.append(["word": word, "start": time.start.seconds, "end": time.end.seconds])
                    if let score = run.transcriptionConfidence { scores.append(score) }
                }
            }
            heard.confidence = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            return heard
        }
        if let end = try await analyzer.analyzeSequence(from: try AVAudioFile(forReading: url)) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await results.value
    }
}
