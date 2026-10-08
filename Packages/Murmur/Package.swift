// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Murmur: Deck's voice core. Recording, transcription, delivery, the dictation chord and the
// dictation preferences. It knows nothing about Alexa or Deck's UI; Deck links it as a static
// library (build.sh compiles it with swiftc; `swift build` here builds it on its own).
//
// whisper.cpp comes from Deck's vendor/whisper, built by vendor/fetch-whisper.sh.
let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../vendor/whisper").standardizedFileURL.path

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Murmur", type: .static, targets: ["Murmur"]),
        .executable(name: "murmur", targets: ["MurmurCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .target(
            name: "Murmur",
            dependencies: ["CWhisper"],
            path: "Sources/Murmur",
            linkerSettings: [
                .unsafeFlags(["-L\(vendor)/lib"]),
                .linkedLibrary("whisper"), .linkedLibrary("ggml"), .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"), .linkedLibrary("ggml-metal"), .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("Accelerate"),
            ]
        ),
        // A command-line front end over the same code, for checks and benchmarks without the app.
        .executableTarget(name: "MurmurCLI", dependencies: ["Murmur"], path: "Sources/MurmurCLI"),
    ],
    swiftLanguageVersions: [.v5]
)
