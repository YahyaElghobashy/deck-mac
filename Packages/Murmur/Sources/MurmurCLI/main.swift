import AppKit
import Carbon
import Foundation
import Murmur
import SQLite3

// murmur transcribe <file.wav> [--lang en|ar|auto] [--model path]
//     Runs the exact transcription path Deck uses and prints the text and the time it took. The
//     input is copied first, because the transcriber deletes its audio on every path.
// murmur transcribe-many <file.wav>… [--lang auto|en|ar] [--prompt none|"text"]
//     Deck's exact in-process path over many files with the model loaded once; one JSON line each.
// murmur bench <file.wav>… [--runs N] [--lang auto|en|ar]
//     Loads the model once, then times N in-process transcriptions per file (DIC-01).
// murmur check-clipboard
//     Exercises clipboard restore on a private pasteboard (never the user's clipboard).
// murmur check-last
//     Checks the 24-hour window for paste-last and copy-last, and the shortcut key codes.
// murmur check-store
//     Creates, migrates, fills, searches and reopens a throwaway database in a temp folder.
// murmur check-language
//     The AUTO language policy on probe results measured on the synthetic set.
// murmur check-gestures
//     Plays timed press/release sequences through ChordGesture: holds, taps, double-taps.
// murmur check-paste
//     Shows which key ⌘V uses on each enabled keyboard layout. Read-only: no layout is switched.

let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

switch args.first {
case "transcribe":
    guard args.count >= 2 else { fail("usage: murmur transcribe <file.wav> [--lang en|ar|auto] [--model path]", code: 64) }
    if let model = value("--model") { DictationPaths.modelPathProvider = { model } }
    let lang = Lang(rawValue: value("--lang") ?? "auto") ?? .auto
    let source = URL(fileURLWithPath: args[1])
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
    do { try FileManager.default.copyItem(at: source, to: copy) } catch {
        fail("cannot read \(source.path): \(error.localizedDescription)", code: 66)
    }
    let promptArg = value("--prompt")
    let prompt: String? = promptArg == "none" ? "" : promptArg   // nil = Deck's default prompt
    let started = Date()
    Transcriber.run(wav: copy, lang: lang, prompt: prompt) { result in
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        WhisperEngine.shared.shutdown()
        switch result {
        case .success(let t): print("\(ms) ms\t\(t.text)  [\(t.engine), \(t.language), infer \(t.inferMs) ms]"); exit(0)
        case .failure(let error): print("\(ms) ms\tERROR \(error.localizedDescription)"); exit(1)
        }
    }
    dispatchMain()

case "probe":
    // murmur probe <file.wav>… [--seconds 2.5]: language detection on the first seconds of each file.
    let files = args.dropFirst().prefix { !$0.hasPrefix("--") }
    let seconds = Double(value("--seconds") ?? "2.5") ?? 2.5
    do {
        for f in files {
            let all = try WavReader.samples(URL(fileURLWithPath: f))
            let head = Array(all.prefix(Int(seconds * 16_000)))
            let t0 = Date()
            let probs = try WhisperEngine.shared.detectLanguage(head, model: DictationPaths.model)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let top = probs.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value * 100))%" }.joined(separator: ", ")
            print("\(URL(fileURLWithPath: f).lastPathComponent)\t\(ms) ms\t\(top)")
        }
    } catch { print("ERROR \(error)") }
    WhisperEngine.shared.shutdown()
    exit(0)

case "transcribe-many":
    let files = args.dropFirst().prefix { !$0.hasPrefix("--") }
    let lang = Lang(rawValue: value("--lang") ?? "auto") ?? .auto
    let promptArg = value("--prompt")
    let prompt: String? = promptArg == "none" ? "" : promptArg      // nil = Deck's default
    let useProbe = lang == .auto && !args.contains("--no-probe")
    for f in files {
        var row: [String: Any] = ["file": f]
        do {
            let samples = try WavReader.samples(URL(fileURLWithPath: f))
            // Like the app: detect the language on the first seconds, if the dictation is long enough.
            let head = Int(LanguagePolicy.probeSeconds * 16_000)
            let probe = useProbe && samples.count > head
                ? try WhisperEngine.shared.detectLanguage(Array(samples.prefix(head)), model: DictationPaths.model) : nil
            let t = try Transcriber.transcribe(samples, lang: lang, probe: probe, prompt: prompt)
            row["decoded_as"] = LanguagePolicy.decide(mode: lang, probe: probe).code
            row["text"] = t.text; row["language"] = t.language; row["infer_ms"] = t.inferMs; row["audio_seconds"] = t.audioSeconds
        } catch { row["error"] = "\(error)" }
        if let d = try? JSONSerialization.data(withJSONObject: row), let s = String(data: d, encoding: .utf8) { print(s) }
    }
    WhisperEngine.shared.shutdown()
    exit(0)

case "bench":
    let files = args.dropFirst().prefix { !$0.hasPrefix("--") }
    let runs = Int(value("--runs") ?? "10") ?? 10
    let lang = value("--lang") ?? "auto"
    let promptArg = value("--prompt")
    let prompt: String? = promptArg == "none" ? nil : (promptArg ?? SpeechPrompt.build(lang: Lang(rawValue: lang) ?? .auto))
    guard !files.isEmpty else { fail("usage: murmur bench <file.wav>… [--runs N] [--lang auto|en|ar]", code: 64) }
    do {
        let first = try WavReader.samples(URL(fileURLWithPath: files.first!))
        let t0 = Date()
        WhisperEngine.shared.preload(model: DictationPaths.model)   // what Deck does on ⌃⌥Z
        _ = WhisperEngine.shared.isLoaded                            // waits for the load and warm-up
        let preloadMs = Int(Date().timeIntervalSince(t0) * 1000)
        let cold = try WhisperEngine.shared.transcribe(first, model: DictationPaths.model, language: lang, prompt: prompt)
        print("preload (load + warm-up) \(preloadMs) ms, first transcription after it \(cold.inferMs) ms")
        for f in files {
            let samples = try WavReader.samples(URL(fileURLWithPath: f))
            var times: [Int] = []
            var last: WhisperEngine.Output?
            for _ in 0..<runs {
                let out = try WhisperEngine.shared.transcribe(samples, model: DictationPaths.model, language: lang, prompt: prompt)
                times.append(out.inferMs); last = out
            }
            times.sort()
            let name = URL(fileURLWithPath: f).lastPathComponent
            print(String(format: "%@  audio %.1f s  ctx %d  p50 %d ms  p95 %d ms  [%@] %@", name, last!.audioSeconds, last!.audioContext,
                         times[times.count / 2], times[min(times.count - 1, Int(Double(times.count) * 0.95))], last!.language,
                         String(last!.text.trimmingCharacters(in: .whitespaces).prefix(70))))
        }
    } catch { print("ERROR \(error)") }
    WhisperEngine.shared.shutdown()
    exit(0)

case "check-clipboard":
    exit(ClipboardCheck.run() ? 0 : 1)

case "check-paste":
    let current = KeyLayout.commandKeyCode(for: "v")
    print("current layout: ⌘V uses key code \(current)\(current == 9 ? " (the V position)" : "")")
    let layouts = (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] ?? []).filter { src in
        guard let t = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return false }
        return (Unmanaged<CFString>.fromOpaque(t).takeUnretainedValue() as String) == (kTISTypeKeyboardLayout as String)
    }
    for src in layouts {
        let name = TISGetInputSourceProperty(src, kTISPropertyLocalizedName).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
        let code = KeyLayout.keyCode(for: "v", in: src).map(String.init) ?? "none on its ⌘ layer, falls back to the shortcut layout"
        print("  \(name): \(code)")
    }
    exit(0)

case "check-store":
    exit(StoreCheck.run() ? 0 : 1)

case "check-language":
    var ok = true
    func expect(_ name: String, _ mode: Lang, _ probe: [String: Float]?, _ code: String, mixed: Bool) {
        let d = LanguagePolicy.decide(mode: mode, probe: probe)
        let pass = d.code == code && d.mixedPrompt == mixed
        print("\(pass ? "PASS" : "FAIL")  \(name)\(pass ? "" : "  (got \(d.code), mixed \(d.mixedPrompt))")"); ok = ok && pass
    }
    expect("pure English (en 99%) decodes as English", .auto, ["en": 0.99], "en", mixed: false)
    expect("pure Arabic (ar 97%) decodes as Arabic with the mixed prompt", .auto, ["ar": 0.97, "en": 0.01], "ar", mixed: true)
    expect("mixed, Arabic-led (ar 48%, en 46%)", .auto, ["ar": 0.48, "en": 0.46], "ar", mixed: true)
    expect("mixed, English-led (en 77%, ar 17%) stays on the Arabic route", .auto, ["en": 0.77, "ar": 0.17], "ar", mixed: true)
    expect("French (fr 99%) decodes as French", .auto, ["fr": 0.99], "fr", mixed: false)
    expect("German (de 99%) decodes as German", .auto, ["de": 0.99], "de", mixed: false)
    expect("too short to probe: English and Arabic route", .auto, nil, "ar", mixed: true)
    expect("EN mode ignores the probe", .english, ["ar": 0.9], "en", mixed: false)
    expect("AR mode ignores the probe", .arabic, ["fr": 0.9], "ar", mixed: true)
    let mixedPrompt = SpeechPrompt.build(mixed: true), englishPrompt = SpeechPrompt.build(mixed: false)
    let pass = mixedPrompt.hasPrefix("بنستخدم HubSpot") && mixedPrompt.contains("workflow في HubSpot") && !englishPrompt.contains("عايز")
    print("\(pass ? "PASS" : "FAIL")  prompts: Arabic-framed terms first for mixed speech, no Arabic for English"); ok = ok && pass
    print(ok ? "all language checks passed" : "language checks FAILED")
    exit(ok ? 0 : 1)

case "check-gestures":
    var ok = true
    func run(_ name: String, _ events: [(String, Double)], expect: [ChordGesture.Action]) {
        var g = ChordGesture()
        var got: [ChordGesture.Action] = []
        for (kind, t) in events {
            let a: ChordGesture.Action
            switch kind {
            case "press": a = g.press(at: t)
            case "release": a = g.release(at: t)
            default: a = g.tick(at: t)
            }
            if a != .none { got.append(a) }
        }
        let pass = got == expect
        print("\(pass ? "PASS" : "FAIL")  \(name)\(pass ? "" : "  (got \(got))")"); ok = ok && pass
    }
    run("hold 2 s then release: push-to-talk", [("press", 0), ("release", 2)], expect: [.start, .finish])
    run("hold just past the tap limit: push-to-talk", [("press", 0), ("release", 0.31)], expect: [.start, .finish])
    run("double-tap within 400 ms locks", [("press", 0), ("release", 0.12), ("press", 0.40), ("release", 0.5)], expect: [.start, .lock])
    run("a press while locked finishes", [("press", 0), ("release", 0.1), ("press", 0.3), ("release", 0.4), ("press", 9), ("release", 9.1)],
        expect: [.start, .lock, .finish])
    run("a lone tap is cancelled after the window", [("press", 0), ("release", 0.1), ("tick", 0.3), ("tick", 0.52)], expect: [.start, .cancelTap])
    run("a second press after the window starts fresh", [("press", 0), ("release", 0.1), ("press", 0.8), ("release", 3)],
        expect: [.start, .start, .finish])
    run("taps with ⌃⌥ held or re-pressed behave the same (the 'Z again' lock)", [("press", 0), ("release", 0.2), ("press", 0.55)],
        expect: [.start, .lock])
    run("a hold right after a finished dictation starts a new one", [("press", 0), ("release", 1.5), ("press", 1.7), ("release", 3.5)],
        expect: [.start, .finish, .start, .finish])
    print(ok ? "all gesture checks passed" : "gesture checks FAILED")
    exit(ok ? 0 : 1)

case "check-last":
    var ok = true
    func check(_ name: String, _ pass: Bool) { print("\(pass ? "PASS" : "FAIL")  \(name)"); ok = ok && pass }
    check("nothing before the first dictation", LastDictation.text == nil)
    LastDictation.record("old", at: Date().addingTimeInterval(-LastDictation.lifetime - 1))
    check("a dictation older than 24 hours is gone", LastDictation.text == nil)
    LastDictation.record("recent", at: Date().addingTimeInterval(-LastDictation.lifetime + 60))
    check("a dictation 23h59m old is still there", LastDictation.text == "recent")
    LastDictation.record("now")
    check("the newest dictation replaces the previous one", LastDictation.text == "now")
    check("⌃⌥V and ⌃⌥C map to their physical keys", DictationKeys.code(for: "v") == 9 && DictationKeys.code(for: "C") == 8)
    check("Z is never offered as a recovery key", DictationKeys.code(for: "z") == nil)
    print(ok ? "all last-dictation checks passed" : "last-dictation checks FAILED")
    exit(ok ? 0 : 1)

default:
    fail("usage: murmur transcribe <file.wav> … | murmur check-clipboard | murmur check-last", code: 64)
}

enum StoreCheck {
    static func run() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("deck.sqlite")
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")"); ok = ok && pass
        }
        do {
            let store = try Store(url: url)
            check("a new database migrates to the latest schema", store.schemaVersion == Store.migrations.count, "version \(store.schemaVersion)")
            let now = Date()
            try store.addDictation(DictationRecord(text: "Move the HubSpot sync to Friday", lang: "en", engine: "whisper-cli",
                                                   delivery: "keystroke", appBundleID: "com.apple.mail", audioSeconds: 3.2, transcribeMs: 840,
                                                   createdAt: now.addingTimeInterval(-60)))
            try store.addDictation(DictationRecord(text: "كلم العميل وقوله إننا محتاجين يومين زيادة", lang: "ar", engine: "whisper-cli",
                                                   delivery: "clipboard", appBundleID: nil, audioSeconds: 4.1, transcribeMs: 910, createdAt: now))
            check("dictations are saved", try store.dictationCount() == 2)
            check("an optional app ID is stored when present and skipped when nil", try store.recentApps() == ["com.apple.mail"])
            check("the latest dictation is the newest one", try store.latestDictation()?.text.hasPrefix("كلم") == true)
            let en = try store.search("hubspot")
            check("full-text search finds English", en.first?.kind == "dictation" && en.first?.snippet.contains("[HubSpot]") == true, en.first?.snippet ?? "no hit")
            let ar = try store.search("العميل")
            check("full-text search finds Arabic", ar.count == 1, ar.first?.snippet ?? "no hit")
            check("the last word matches as a prefix", try store.search("hub").count == 1)
            check("an empty query returns nothing", try store.search("   ").isEmpty)
            try store.setSetting("theme", "dark"); try store.setSetting("theme", "light")
            check("settings upsert", try store.setting("theme") == "light")
        } catch { check("store operations", false, "\(error)") }
        do {
            let reopened = try Store(url: url)
            check("reopening keeps the data and the schema", try reopened.dictationCount() == 2 && reopened.schemaVersion == Store.migrations.count)
            for ms in [100, 200, 300, 400, 1000] { try reopened.addMetric("release_to_text.whisper", ms: ms) }
            try reopened.addMetric("delivery.keystroke")
            let sums = try reopened.metricSummaries()
            let rt = sums.first { $0.path == "release_to_text.whisper" }
            check("metrics: p50 and p95 per path", rt?.count == 5 && rt?.p50 == 300 && rt?.p95 == 1000, "p50 \(rt?.p50 ?? -1) p95 \(rt?.p95 ?? -1)")
            check("metrics: plain counts have no timing", sums.first { $0.path == "delivery.keystroke" }.map { $0.count == 1 && $0.p50 == nil } == true)
            try reopened.clearMetrics()
            check("metrics can be cleared", try reopened.metricSummaries().isEmpty)
        } catch { check("reopen and metrics", false, "\(error)") }

        // An existing database at schema v1 (what Deck 1.1.0 created) upgrades in place.
        let oldURL = dir.appendingPathComponent("v1.sqlite")
        var db: OpaquePointer?
        sqlite3_open(oldURL.path, &db)
        for sql in Store.migrations[0] + ["INSERT INTO dictations(created_at, text) VALUES (1, 'kept across the upgrade')", "PRAGMA user_version = 1"] {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        sqlite3_close(db)
        do {
            let upgraded = try Store(url: oldURL)
            try upgraded.addMetric("model_load", ms: 2500)
            let kept = try upgraded.latestDictation()?.text
            check("a v1 database upgrades to the latest schema and keeps its rows",
                  upgraded.schemaVersion == Store.migrations.count && kept == "kept across the upgrade", "version \(upgraded.schemaVersion)")
        } catch { check("upgrade from v1", false, "\(error)") }
        print(ok ? "all store checks passed" : "store checks FAILED")
        return ok
    }
}

enum ClipboardCheck {
    static let pb = NSPasteboard(name: NSPasteboard.Name("com.yahya.deck.selftest"))
    static let rtf = NSPasteboard.PasteboardType.rtf

    static func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func set(_ s: String) { pb.clearContents(); pb.setString(s, forType: .string) }
    static var current: String? { pb.string(forType: .string) }
    static var types: [NSPasteboard.PasteboardType] { pb.pasteboardItems?.first?.types ?? [] }

    static func run() -> Bool {
        let session = ClipboardSession(pasteboard: pb)
        session.restoreDelay = 0.15
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
            ok = ok && pass
        }

        // 1. Fifty dictations at random gaps, some shorter and some longer than the restore delay.
        set("ORIGINAL")
        for i in 0..<50 {
            session.put("dictation \(i)", restore: true)
            pump(Double.random(in: 0...0.3))
        }
        pump(0.4)
        check("50 rapid dictations end on the original clipboard", current == "ORIGINAL", "got \(current ?? "nil")")

        // 2. Something copied during the restore window wins.
        set("A")
        session.put("dictated", restore: true)
        pump(0.05)
        set("USER COPY")
        pump(0.3)
        check("a copy made during the window is kept", current == "USER COPY", "got \(current ?? "nil")")

        // 3. Markers: concealed always, transient only when it will be restored.
        set("A")
        session.put("pasted", restore: true)
        let pastedTypes = types
        pump(0.3)
        session.put("left for the user", restore: false)
        let leftTypes = types
        check("pasted text is concealed and transient",
              pastedTypes.contains(.init("org.nspasteboard.ConcealedType")) && pastedTypes.contains(.init("org.nspasteboard.TransientType")))
        check("text left on the clipboard is concealed, not transient",
              leftTypes.contains(.init("org.nspasteboard.ConcealedType")) && !leftTypes.contains(.init("org.nspasteboard.TransientType")))

        // 4. A transcript left on the clipboard comes back after the next pasted dictation.
        session.put("next", restore: true)
        pump(0.3)
        check("an unpasted transcript survives the next dictation", current == "left for the user", "got \(current ?? "nil")")

        // 5. Rich contents keep every type.
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("rich", forType: .string)
        item.setData("{\\rtf1 rich}".data(using: .utf8)!, forType: rtf)
        pb.writeObjects([item])
        session.put("dictated", restore: true)
        pump(0.3)
        check("string and RTF both restored", current == "rich" && pb.data(forType: rtf) != nil)

        // 6. An empty clipboard stays empty.
        pb.clearContents()
        session.put("dictated", restore: true)
        pump(0.3)
        check("an empty clipboard is restored as empty", (pb.pasteboardItems ?? []).isEmpty)

        pb.releaseGlobally()
        print(ok ? "all clipboard checks passed" : "clipboard checks FAILED")
        return ok
    }
}
