import AppKit
import Foundation
import Murmur

// murmur transcribe <file.wav> [--lang en|ar|auto] [--model path]
//     Runs the exact transcription path Deck uses and prints the text and the time it took. The
//     input is copied first, because the transcriber deletes its audio on every path.
// murmur check-clipboard
//     Exercises clipboard restore on a private pasteboard (never the user's clipboard).
// murmur check-last
//     Checks the 24-hour window for paste-last and copy-last, and the shortcut key codes.

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
    let started = Date()
    Transcriber.run(wav: copy, lang: lang) { result in
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success(let text): print("\(ms) ms\t\(text)"); exit(0)
        case .failure(let error): print("\(ms) ms\tERROR \(error.localizedDescription)"); exit(1)
        }
    }
    dispatchMain()

case "check-clipboard":
    exit(ClipboardCheck.run() ? 0 : 1)

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
