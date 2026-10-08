import Foundation
import Murmur

// murmur transcribe <file.wav> [--lang en|ar|auto] [--model path]
// Runs the exact transcription path Deck uses and prints the text and the time it took.
// The input is copied first, because the transcriber deletes its audio on every path.

let args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard args.first == "transcribe", args.count >= 2 else {
    FileHandle.standardError.write("usage: murmur transcribe <file.wav> [--lang en|ar|auto] [--model path]\n".data(using: .utf8)!)
    exit(64)
}
if let model = value("--model") { DictationPaths.modelPathProvider = { model } }
let lang = Lang(rawValue: value("--lang") ?? "auto") ?? .auto
let source = URL(fileURLWithPath: args[1])
let copy = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
do { try FileManager.default.copyItem(at: source, to: copy) } catch {
    FileHandle.standardError.write("cannot read \(source.path): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(66)
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
