import Foundation
import WidgetKit

/// `deck://action?kind=…&target=…` — what the widget's tiles and player buttons open. Runs the same
/// bridge calls the App Intent would, then refreshes the widgets.
enum WidgetActions {
    @MainActor
    static func handle(_ url: URL) async {
        var kind = "", target = ""
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if item.name == "kind" { kind = item.value ?? "" }
            if item.name == "target" { target = item.value ?? "" }
        }
        DebugLog.write("widget action \(kind) \(target)")
        do {
            switch kind {
            case "listen": HUDController.shared.toggleListening()
            case "entity-toggle": try await BridgeClient.toggleEntity(id: target)
            case "text": _ = try await BridgeClient.sendText(target)
            case "routine": try await BridgeClient.runRoutine(id: target)
            case "player": try await BridgeClient.player(target)
            case "refresh": try await BridgeClient.refresh()
            default: DebugLog.write("widget action: unknown kind \(kind)")
            }
            DebugLog.write("widget action done \(kind) \(target)")
        } catch {
            DebugLog.write("widget action failed \(kind) \(target): \(error.localizedDescription)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
