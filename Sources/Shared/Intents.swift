import AppIntents
import Foundation

/// One intent for every widget button. `kind` decides what happens:
///   listen            → wakes the app's push-to-talk (distributed notification)
///   entity-toggle     → bridge toggles a smart-home entity (id)
///   text              → bridge types a command to the Echo (target)
///   routine           → bridge runs a routine (id)
///   player            → play | pause | next | previous
///   refresh           → bridge refreshes its cache
struct DeckActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Deck Action"
    static var description = IntentDescription("Runs a Deck widget button.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Kind")
    var kind: String

    @Parameter(title: "Target")
    var target: String

    init() {}

    init(kind: String, target: String) {
        self.kind = kind
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        DebugLog.write("intent \(kind) \(target)")
        do {
            switch kind {
            case "listen":
                DistributedNotificationCenter.default().postNotificationName(DeckPaths.listenNotification, object: nil, userInfo: nil, deliverImmediately: true)
            case "entity-toggle":
                try await BridgeClient.toggleEntity(id: target)
            case "text":
                _ = try await BridgeClient.sendText(target)
            case "routine":
                try await BridgeClient.runRoutine(id: target)
            case "player":
                try await BridgeClient.player(target)
            case "refresh":
                try await BridgeClient.refresh()
            default:
                DebugLog.write("intent: unknown kind \(kind)")
            }
            DebugLog.write("intent done \(kind) \(target)")
        } catch {
            DebugLog.write("intent failed \(kind) \(target): \(error.localizedDescription)")
        }
        return .result()
    }
}
