import AppKit
import Carbon
import Foundation
import Murmur
import SQLite3

// murmur transcribe <file.wav> [--lang en|ar|auto] [--model path]
//     Runs the exact transcription path Deck uses and prints the text and the time it took. The
//     input is copied first, because the transcriber deletes its audio on every path.
// murmur transcribe-many <file.wav>… [--lang auto|en|ar]
//     Deck's whole-recording path (phrase by phrase in AUTO) over many files with the model loaded
//     once; one JSON line each.
// murmur bench <file.wav>… [--runs N] [--lang auto|en|ar]
//     Loads the model once, then times N in-process transcriptions per file (DIC-01).
// murmur check-clipboard
//     Exercises clipboard restore on a private pasteboard (never the user's clipboard).
// murmur check-last
//     Checks the 24-hour window for paste-last and copy-last, and the shortcut key codes.
// murmur check-store
//     Creates, migrates, fills, searches and reopens a throwaway database in a temp folder.
// murmur stream <file.wav> [--speed 1] [--lang auto|en|ar]
//     Replays a file as a live recording (audio grows every 250 ms), transcribing at pauses the
//     way Deck does, and prints release-to-text, the pieces and the joined text as JSON.
// murmur cuts <file.wav>
//     Where PauseChunker puts phrase boundaries and piece cuts, each phrase's probe, and each phrase
//     decoded alone in its own language.
// murmur check-paste-verdict
//     DEL-03's decision from the field before and after a paste, on edge cases.
// murmur check-language
//     The AUTO language policy: per-phrase routes, short phrases borrowing a neighbour's language,
//     the prompts.
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

// Any command: --model path (or MURMUR_MODEL=path) uses another whisper model, for comparisons.
if let model = value("--model") ?? ProcessInfo.processInfo.environment["MURMUR_MODEL"] {
    DictationPaths.modelPathProvider = { model }
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
    let started = Date()
    Transcriber.run(wav: copy, lang: lang) { result in
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
    if let c = value("--ctx").flatMap(Int32.init) { WhisperEngine.shared.probeAudioContext = c }
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
    for f in files {
        var row: [String: Any] = ["file": f]
        do {
            let samples = try WavReader.samples(URL(fileURLWithPath: f))
            let t = try StreamingTranscriber.transcribeAll(samples, lang: lang, model: DictationPaths.model)
            row["text"] = t.text; row["language"] = t.language; row["infer_ms"] = t.inferMs; row["audio_seconds"] = t.audioSeconds
        } catch VoiceError.empty {
            row["text"] = ""
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

case "stream":
    guard args.count >= 2 else { fail("usage: murmur stream <file.wav> [--speed 1] [--lang auto|en|ar]", code: 64) }
    let speed = Double(value("--speed") ?? "1") ?? 1
    let lang = Lang(rawValue: value("--lang") ?? "auto") ?? .auto
    do {
        let all = try WavReader.samples(URL(fileURLWithPath: args[1]))
        WhisperEngine.shared.preload(model: DictationPaths.model)    // as on key press
        _ = WhisperEngine.shared.isLoaded
        let stream = StreamingTranscriber(lang: lang, model: DictationPaths.model)
        var events: [String] = []
        stream.onEvent = { kind, ms, detail in events.append("\(kind) \(ms) ms \(detail ?? "")") }
        var fed = 0
        while fed < all.count {
            fed = min(all.count, fed + 4_000)
            stream.feed(Array(all.prefix(fed)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.25 / speed))
        }
        let released = Date()
        stream.finish(all) { result in
            let ms = Int(Date().timeIntervalSince(released) * 1000)
            var row: [String: Any] = ["file": args[1], "release_ms": ms, "pieces": stream.piecesSoFar + 1, "events": events,
                                      "audio_seconds": Double(all.count) / 16_000]
            switch result {
            case .success(let t): row["text"] = t.text; row["language"] = t.language
            case .failure(let e): row["error"] = "\(e)"
            }
            if let d = try? JSONSerialization.data(withJSONObject: row), let s = String(data: d, encoding: .utf8) { print(s) }
            WhisperEngine.shared.shutdown()
            exit(0)
        }
        RunLoop.main.run()
    } catch { fail("ERROR \(error)", code: 1) }

case "cuts":
    do {
        let all = try WavReader.samples(URL(fileURLWithPath: args[1]))
        var chunker = PauseChunker()
        var fed = 0
        while fed < all.count { fed = min(all.count, fed + 4_000); _ = chunker.feed(Array(all.prefix(fed))) }
        let bounds = [0] + chunker.phraseCuts.filter { $0 < all.count } + [all.count]
        let pieceCuts = Set(chunker.cuts)
        for i in 0..<(bounds.count - 1) {
            let phrase = Array(all[bounds[i]..<bounds[i + 1]])
            let seconds = Double(phrase.count) / 16_000
            let probe = try WhisperEngine.shared.detectLanguage(phrase, model: DictationPaths.model)
            let top3 = probe.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value * 100))%" }.joined(separator: ", ")
            let code = LanguagePolicy.top(probe) ?? "ar"
            let t = try Transcriber.transcribe(phrase + [Float](repeating: 0, count: 8_000), language: code,
                                               prompt: SpeechPrompt.build(language: code))
            print(String(format: "%@ %.2f–%.2f s (%.1f s%@)  probe %@  → %@", pieceCuts.contains(bounds[i]) ? "▌" : " ",
                         Double(bounds[i]) / 16_000, Double(bounds[i + 1]) / 16_000, seconds,
                         seconds < LanguagePolicy.minPhraseSeconds ? ", short" : "", top3, code))
            print("     \(t.text)")
        }
    } catch { print("ERROR \(error)") }
    WhisperEngine.shared.shutdown()
    exit(0)

case "track":
    // murmur track <file.wav> [--win 1.5] [--hop 0.5] [--ctx 256]: the language of a sliding window.
    let win = Double(value("--win") ?? "1.5") ?? 1.5, hop = Double(value("--hop") ?? "0.5") ?? 0.5
    if let c = value("--ctx").flatMap(Int32.init) { WhisperEngine.shared.probeAudioContext = c }
    do {
        let all = try WavReader.samples(URL(fileURLWithPath: args[1]))
        var t = 0.0
        var line = ""
        var total = 0
        while Int((t + win) * 16_000) <= all.count {
            let w = Array(all[Int(t * 16_000)..<Int((t + win) * 16_000)])
            let t0 = Date()
            let p = try WhisperEngine.shared.detectLanguage(w, model: DictationPaths.model)
            total += Int(Date().timeIntervalSince(t0) * 1000)
            let top = p.max { $0.value < $1.value }!
            line += String(format: "%.1f:%@%d ", t + win / 2, top.key, Int(top.value * 100))
            t += hop
        }
        print(line); print("probe time \(total) ms")
    } catch { print("ERROR \(error)") }
    WhisperEngine.shared.shutdown()
    exit(0)

case "compare":
    // murmur compare <file.wav>… --langs de,en: each file decoded in each language, as JSON lines.
    let files = args.dropFirst().prefix { !$0.hasPrefix("--") }
    let langs = (value("--langs") ?? "en,ar").split(separator: ",").map(String.init)
    for f in files {
        var row: [String: Any] = ["file": f]
        do {
            let samples = try WavReader.samples(URL(fileURLWithPath: f)) + [Float](repeating: 0, count: 8_000)
            for l in langs {
                let t = try Transcriber.transcribe(samples, language: l, prompt: SpeechPrompt.build(language: l))
                row[l] = t.text
            }
        } catch { row["error"] = "\(error)" }
        if let d = try? JSONSerialization.data(withJSONObject: row), let s = String(data: d, encoding: .utf8) { print(s) }
    }
    WhisperEngine.shared.shutdown()
    exit(0)

case "check-paste-verdict":
    var ok = true
    func expect(_ name: String, _ before: String?, _ after: String?, _ text: String, _ v: PasteVerdict) {
        let got = PasteCheck.verdict(before: before, after: after, inserted: text)
        print("\(got == v ? "PASS" : "FAIL")  \(name)\(got == v ? "" : "  (got \(got))")"); ok = ok && got == v
    }
    let t = "Move the HubSpot sync to Friday."
    expect("empty field now holds the text", "", t, t, .landed)
    expect("text added at the end", "Hi Sarah,\n", "Hi Sarah,\n" + t, t, .landed)
    expect("text replaced a selection", "Hi Sarah, PLACEHOLDER thanks", "Hi Sarah, \(t) thanks", t, .landed)
    expect("Arabic text added", "", "كلم العميل وقوله إننا محتاجين يومين", "كلم العميل وقوله إننا محتاجين يومين", .landed)
    expect("app reformatted the text but it is longer", "a", "a • move the hubspot sync to friday", t, .landed)
    expect("field unchanged: the paste didn't land", "Hi Sarah,", "Hi Sarah,", t, .failed)
    expect("field unreadable before: no alarm", nil, "anything", t, .unknown)
    expect("field unreadable after: no alarm", "Hi", nil, t, .unknown)
    expect("field changed some other way: no alarm", "Hello world", "Hello", t, .unknown)
    expect("huge document: not compared", String(repeating: "x", count: 200_000), String(repeating: "x", count: 200_000), t, .unknown)
    print(ok ? "all paste-verdict checks passed" : "paste-verdict checks FAILED")
    exit(ok ? 0 : 1)

case "check-language":
    var ok = true
    func check(_ name: String, _ pass: Bool, _ got: String = "") {
        print("\(pass ? "PASS" : "FAIL")  \(name)\(pass || got.isEmpty ? "" : "  (got \(got))")"); ok = ok && pass
    }
    func route(_ name: String, _ probe: [String: Float], _ code: String, mixed: Bool) {
        let d = LanguagePolicy.route(LanguagePolicy.top(probe) ?? "?")
        check(name, d.code == code && d.mixedPrompt == mixed, "\(d.code), mixed \(d.mixedPrompt)")
    }
    route("Arabic phrase (ar 97%): Arabic token with the mixed prompt", ["ar": 0.97, "en": 0.01], "ar", mixed: true)
    route("English phrase (en 98%): English token", ["en": 0.98], "en", mixed: false)
    route("German phrase with English present (de 51%, en 7%): German, never the Arabic route (8 Oct)",
          ["de": 0.51, "en": 0.07, "nl": 0.05], "de", mixed: false)
    route("Accented English (en 90%, ar 5%): English", ["en": 0.90, "ar": 0.05], "en", mixed: false)
    route("Arabic with English terms (ar 70%, en 25%): Arabic route keeps the terms", ["ar": 0.70, "en": 0.25], "ar", mixed: true)
    route("French (fr 95%): French", ["fr": 0.95, "en": 0.03], "fr", mixed: false)
    func resolve(_ name: String, _ heard: [String?], before: String?, _ want: [String?]) {
        let got = LanguagePolicy.resolve(heard, before: before)
        check(name, got == want, got.map { $0 ?? "nil" }.joined(separator: " "))
    }
    resolve("short phrases take the previous phrase's language", ["ar", nil, "en", nil], before: nil, ["ar", "ar", "en", "en"])
    resolve("a short phrase opening a piece takes the next one's", [nil, "de", "en"], before: "ar", ["de", "de", "en"])
    resolve("a piece of short phrases takes the dictation's last language", [nil, nil], before: "en", ["en", "en"])
    resolve("nothing to go on stays unknown", [nil], before: nil, [nil])
    resolve("your 8 Oct dictation, phrase by phrase", ["ar", "en", "de", nil], before: nil, ["ar", "en", "de", "de"])
    func short(_ name: String, _ probe: [String: Float], _ want: String?) {
        let got = LanguagePolicy.shortPhrase(probe)
        check(name, got == want, got ?? "borrow")
    }
    short("short German, clear (de 60%, en 34%): keeps German (8 Oct)", ["de": 0.60, "en": 0.34], "de")
    short("short German heard as English (en 83%): borrows", ["en": 0.83, "pt": 0.03], nil)
    short("short Arabic heard as Hungarian (hu 45%): borrows", ["hu": 0.45, "en": 0.14], nil)
    short("short clear English (en 99%): keeps English", ["en": 0.99], "en")
    check("may be mixed: en 56% + de 30% (no pause between them)", LanguagePolicy.mayBeMixed(["en": 0.56, "de": 0.30, "ar": 0.02]))
    check("may be mixed: en 46% + de 13% (three languages, no pause)", LanguagePolicy.mayBeMixed(["en": 0.46, "de": 0.13, "ja": 0.04]))
    check("not mixed: ar 97%", !LanguagePolicy.mayBeMixed(["ar": 0.97, "en": 0.01]))
    check("not mixed: en 93% + de 4%", !LanguagePolicy.mayBeMixed(["en": 0.93, "de": 0.04]))
    func runs(_ name: String, _ windows: String, _ want: String) {
        // "ar99 en46 -": language and share per window, "-" for none.
        let parsed: [(language: String, share: Float)?] = windows.split(separator: " ").map { w in
            w == "-" ? nil : (String(w.prefix(2)), Float(w.dropFirst(2))! / 100)
        }
        let got = LanguagePolicy.runs(parsed).map { "\($0.language)\($0.first)-\($0.last)" }.joined(separator: " ")
        check(name, got == want, got)
    }
    // Window shares measured on the one-voice test lines (1.5 s windows every 0.5 s).
    runs("tight Arabic → English → German line", "ar97 ar97 ar89 ar96 en52 en96 en98 en99 en81 de77 de90 de47", "ar0-3 en5-8 de9-10")
    runs("mid-sentence English → Arabic → German (German only at the end)", "en97 en87 en48 ar89 ar95 ar85 en33 en53 de65 de99",
         "en0-1 ar3-5 de9-9")
    runs("Arabic with one English term (a lone clear window inside)", "ar95 ar90 en92 ar88 ar93", "ar0-4")
    runs("a lone window at the end must be very clear", "ar95 ar90 ar88 en80", "ar0-2")
    runs("all unclear", "en40 ar50 -", "")
    do {
        // A tone with a 40 ms gap at 1.0 s: the quietest point between 0.7 and 1.3 s is the gap.
        var tone = (0..<32_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        for i in 16_000..<16_640 { tone[i] = 0 }
        let q = PauseChunker.quietest(tone, from: 11_200, to: 20_800)
        check("quietest point lands in the gap", (16_000...16_640).contains(q), "\(q)")
    }
    func terms(_ name: String, _ langs: [String?], _ seconds: [Double], before: String?, _ want: [String?]) {
        let got = LanguagePolicy.attachTerms(langs, seconds: seconds, before: before)
        check(name, got == want, got.map { $0 ?? "nil" }.joined(separator: " "))
    }
    terms("an English term between Arabic joins the Arabic", ["ar", "en", "ar"], [1.5, 0.9, 1.2], before: nil, ["ar", "ar", "ar"])
    terms("an English term inside German joins the German", ["de", "en", "de"], [0.9, 0.7, 1.4], before: nil, ["de", "de", "de"])
    terms("a full English sentence stays English (8 Oct)", ["ar", "en", "de"], [3.5, 2.0, 1.7], before: nil, ["ar", "en", "de"])
    terms("English terms with nothing else around stay English", ["en", "en"], [0.9, 1.0], before: nil, ["en", "en"])
    terms("a term opening a piece joins the language before it", ["en", "ar"], [0.8, 2.0], before: "ar", ["ar", "ar"])
    check("a term on its own is not a prompt echo", !SpeechPrompt.isEcho("HubSpot.", of: SpeechPrompt.build(language: "en")))
    check("a sentence of the prompt is", SpeechPrompt.isEcho("أنا عايز أخلص الحاجة دي النهارده، ماشي؟", of: SpeechPrompt.build(language: "ar")))
    check("EN mode forces English", LanguagePolicy.forced(.english) == "en")
    check("AR mode forces Arabic", LanguagePolicy.forced(.arabic) == "ar")
    check("AUTO forces nothing", LanguagePolicy.forced(.auto) == nil)
    let ar = SpeechPrompt.build(language: "ar"), en = SpeechPrompt.build(language: "en"), de = SpeechPrompt.build(language: "de")
    let arabic: (String) -> Bool = { $0.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }
    check("Arabic prompt: Arabic-framed terms first, then the mixed example",
          ar.hasPrefix("بنستخدم HubSpot") && ar.contains("workflow في HubSpot"))
    check("English and German prompts carry no Arabic", !arabic(en) && !arabic(de) && en.hasPrefix("Terms:"))
    for (input, want) in [("أنا بجرب الإملاء دلوقتي. ترجمة نانسي قنقر", "أنا بجرب الإملاء دلوقتي."),
                          ("Ich teste jetzt das Diktat. Untertitel im Auftrag des ZDF", "Ich teste jetzt das Diktat."),
                          ("\"بطي تشكت مر\" \"بطي تشكت مر\" \"بطي تشكت مر\" \"بطي تشكت مر\"", "\"بطي تشكت مر\""),
                          ("no no no, that's not it", "no no no, that's not it"),
                          ("very very good", "very very good"),
                          // large-v3's repeats on the one-voice lines (9 Oct)
                          ("أنا بجرب الإملاء دلوقتي. أنا بجرب الإملاء دلوقتي. I'm testing the dictation now.",
                           "أنا بجرب الإملاء دلوقتي. I'm testing the dictation now."),
                          ("وبشوف بقى أنت عادي في الحتة دي وبشوف بقى أنت عادي في الحتة دي", "وبشوف بقى أنت عادي في الحتة دي"),
                          ("I'm testing the dictation now. I'm testing the dictation now.", "I'm testing the dictation now.")] {
        let got = Transcriber.clean(input)
        check("clean-up: \(input.prefix(30))", got == want, got)
    }
    for (previous, text, want) in [("أنا بجرب الخاصية دي دلوقتي.", "أنا بجرب الخاصية دي دلوقتي. وبعدين نشوف.", "وبعدين نشوف."),
                                   ("First part. Send the report to Mariam.", "Send the report to Mariam. Then call her.", "Then call her."),
                                   ("Send it.", "Send it now please.", "Send it now please."),
                                   ("Quick update.", "Bitte schickt mir die Zahlen.", "Bitte schickt mir die Zahlen.")] {
        let got = Transcriber.dropEcho(of: previous, from: text)
        check("echo of the text before: \(text.prefix(26))", got == want, got)
    }
    check("Accurate model sits next to the fast one",
          SpeechModel.accurate.path(besides: "/m/ggml-large-v3-turbo.bin") == "/m/ggml-large-v3.bin"
          && SpeechModel.fast.path(besides: "/m/ggml-large-v3-turbo.bin") == "/m/ggml-large-v3-turbo.bin")
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
