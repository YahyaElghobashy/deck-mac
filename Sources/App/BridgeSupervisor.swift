import Foundation

/// Keeps the Node bridge alive. If a bridge is already answering on the port (e.g. started by
/// hand), it just attaches instead of spawning a second one.
@MainActor
final class BridgeSupervisor: ObservableObject {
    static let shared = BridgeSupervisor()

    @Published var running = false
    @Published var detail = "starting…"

    private var process: Process?
    private var stopping = false
    private var restartDelay: TimeInterval = 2

    static var bridgeDir: URL {
        // Prefer a checked-out bridge next to the project during development, else the bundled copy.
        let dev = URL(fileURLWithPath: "/Users/yahyaelghobashy/Yahya/Side Projects 🚀/Deck/bridge")
        if FileManager.default.fileExists(atPath: dev.appendingPathComponent("node_modules").path) { return dev }
        return Bundle.main.resourceURL!.appendingPathComponent("bridge")
    }

    static func nodePath() -> String? {
        var candidates: [String] = []
        // Self-contained install: the official arm64 Node binary ships inside the app.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bridge/bin/node").path { candidates.append(bundled) }
        let nvm = DeckPaths.realHome.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append(nvm.appendingPathComponent("\(v)/bin/node").path)
            }
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var health: Timer?

    func start() {
        stopping = false
        Task {
            if await BridgeClient.isUp() {
                running = true
                detail = "attached to running bridge"
                DebugLog.write("bridge already up; attaching")
            } else {
                spawn()
            }
        }
        // An attached bridge can die without telling us; check and respawn.
        health?.invalidate()
        health = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopping, self.process == nil else { return }
                if !(await BridgeClient.isUp()) {
                    DebugLog.write("bridge gone; spawning")
                    self.spawn()
                }
            }
        }
    }

    private func spawn() {
        guard let node = BridgeSupervisor.nodePath() else {
            detail = "node not found (install Node 20 via nvm/brew)"
            DebugLog.write("node not found")
            return
        }
        let dir = BridgeSupervisor.bridgeDir
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [dir.appendingPathComponent("bridge.js").path]
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                self.detail = "bridge exited (\(proc.terminationStatus))"
                DebugLog.write("bridge exited \(proc.terminationStatus)")
                if !self.stopping {
                    let delay = self.restartDelay
                    self.restartDelay = min(30, self.restartDelay * 2)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self.spawn()
                }
            }
        }
        do {
            try p.run()
            process = p
            running = true
            detail = "bridge pid \(p.processIdentifier)"
            DebugLog.write("spawned bridge pid \(p.processIdentifier) with \(node)")
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if await BridgeClient.isUp() { restartDelay = 2 }
            }
        } catch {
            detail = "spawn failed: \(error.localizedDescription)"
            DebugLog.write("spawn failed \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        running = false
    }
}
