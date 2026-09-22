import Foundation
import Combine
import WidgetKit
import AppKit

/// In-app view of the shared files, refreshed when the bridge rewrites them.
@MainActor
final class DeckStore: ObservableObject {
    static let shared = DeckStore()

    @Published private(set) var state = AlexaState.load()
    @Published var actions = DeckActions.load()
    @Published var settings = DeckSettings.load()
    @Published var bridgeUp = false
    @Published var busyTile: String? = nil
    @Published var toast: String? = nil

    private var timer: Timer?
    private var lastMod: Date = .distantPast

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await self.pingBridge() }
    }

    private func tick() {
        let mod = (try? FileManager.default.attributesOfItem(atPath: DeckPaths.alexaState.path)[.modificationDate] as? Date) ?? .distantPast
        if mod != lastMod {
            lastMod = mod
            state = AlexaState.load()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func pingBridge() async {
        bridgeUp = await BridgeClient.isUp()
    }

    func reloadFromDisk() {
        state = AlexaState.load()
        actions = DeckActions.load()
        settings = DeckSettings.load()
    }

    func saveActions() {
        actions.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func saveSettings() {
        settings.save()
    }

    func entity(for tile: Tile) -> SmartEntity? {
        guard tile.kind == .entity else { return nil }
        return state.smarthome.first { $0.id == tile.target } ?? state.entity(named: tile.target)
    }

    func run(_ tile: Tile) {
        busyTile = tile.id
        Task {
            defer { busyTile = nil }
            do {
                switch tile.kind {
                case .entity:
                    guard let e = entity(for: tile) else { flash("No Alexa device called “\(tile.target)”"); return }
                    try await BridgeClient.toggleEntity(id: e.id)
                    flash("\(tile.label) → \(e.isOn ? "off" : "on")")
                case .text:
                    _ = try await BridgeClient.sendText(tile.target, device: tile.device)
                    flash("Sent: “\(tile.target)”")
                case .routine:
                    try await BridgeClient.runRoutine(id: tile.target)
                    flash("Routine: \(tile.label)")
                case .listen:
                    NotificationCenter.default.post(name: DeckPaths.listenNotification, object: nil)
                }
            } catch {
                flash("Failed: \(error.localizedDescription)")
            }
        }
    }

    func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == text { toast = nil }
        }
    }

    func openLogin() {
        Task {
            if let url = try? await BridgeClient.login(), let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            } else if let u = URL(string: "http://127.0.0.1:47832/") {
                NSWorkspace.shared.open(u)
            }
        }
    }

    func setRegion(_ page: String) {
        Task { try? await BridgeClient.setConfig(["amazonPage": page]) }
    }

    func setDefaultDevice(_ name: String) {
        Task { try? await BridgeClient.setConfig(["defaultDevice": name]) }
    }
}
