// swift-tools-version: 5.9
import PackageDescription

// Murmur: Deck's voice core. Recording, transcription, delivery, the dictation chord and the
// dictation preferences. It knows nothing about Alexa or Deck's UI; Deck links it as a static
// library (build.sh compiles it with swiftc; `swift build` here builds it on its own).
let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Murmur", type: .static, targets: ["Murmur"]),
        .executable(name: "murmur", targets: ["MurmurCLI"]),
    ],
    targets: [
        .target(name: "Murmur", path: "Sources/Murmur"),
        // A command-line front end over the same code, for checks and benchmarks without the app.
        .executableTarget(name: "MurmurCLI", dependencies: ["Murmur"], path: "Sources/MurmurCLI"),
    ],
    swiftLanguageVersions: [.v5]
)
