import Foundation

/// Thin async client for the local Node bridge (loopback, token in a header).
struct BridgeClient {
    static let base = URL(string: "http://127.0.0.1:\(DeckPaths.bridgePort)")!

    static var token: String {
        (try? String(contentsOf: DeckPaths.bridgeToken, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    struct BridgeError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func url(_ path: String) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        comps.path = "/" + parts[0]
        comps.query = parts.count > 1 ? parts[1] : nil
        return comps.url ?? base
    }

    static func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> [String: Any] {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(token, forHTTPHeaderField: "X-Deck-Token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw BridgeError(message: (json["error"] as? String) ?? "bridge error \(http.statusCode)")
        }
        return json
    }

    static func requestArray(_ method: String, _ path: String) async throws -> [[String: Any]] {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Deck-Token")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    // MARK: convenience

    static func status() async -> [String: Any] { (try? await request("GET", "status", timeout: 3)) ?? [:] }
    static func isUp() async -> Bool { !(await status()).isEmpty }
    static func login() async throws -> String { (try await request("POST", "login"))["url"] as? String ?? "" }
    static func setConfig(_ cfg: [String: Any]) async throws { _ = try await request("POST", "config", body: cfg) }
    static func refresh() async throws { _ = try await request("POST", "refresh", timeout: 60) }
    static func toggleEntity(id: String) async throws { _ = try await request("POST", "smarthome", body: ["id": id, "action": "toggle"]) }
    static func setEntity(id: String, on: Bool) async throws { _ = try await request("POST", "smarthome", body: ["id": id, "action": on ? "on" : "off"]) }
    static func sendText(_ text: String, device: String? = nil) async throws -> Double {
        var body: [String: Any] = ["text": text]
        if let device { body["device"] = device }
        let r = try await request("POST", "text", body: body)
        return (r["at"] as? Double) ?? Date().timeIntervalSince1970 * 1000
    }
    static func reply(after: Double) async throws -> (pending: Bool, exchange: AlexaExchange?) {
        let r = try await request("GET", "reply?after=\(Int(after))", timeout: 8)
        let pending = (r["pending"] as? Bool) ?? false
        var ex: AlexaExchange? = nil
        if let e = r["exchange"] as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: e) {
            ex = try? JSONDecoder().decode(AlexaExchange.self, from: d)
        }
        return (pending, ex)
    }
    static func runRoutine(id: String) async throws { _ = try await request("POST", "routine", body: ["id": id, "name": id]) }
    static func player(_ command: String, value: Any? = nil) async throws {
        var body: [String: Any] = ["command": command]
        if let value { body["value"] = value }
        _ = try await request("POST", "command", body: body)
    }
    static func speak(_ text: String) async throws { _ = try await request("POST", "speak", body: ["text": text]) }
}
