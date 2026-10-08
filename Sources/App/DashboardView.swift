import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: DeckStore
    @ObservedObject private var bridge = BridgeSupervisor.shared
    @Local private var newLabel = ""
    @Local private var newCommand = ""
    @Local private var pickerEntity = ""
    @Local private var history: [AlexaExchange] = []

    private let regions = ["amazon.de", "amazon.com", "amazon.co.uk", "amazon.it", "amazon.fr", "amazon.es", "amazon.ae", "amazon.sa"]
    private let tileColumns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Deck").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Text("Alexa + dictation on your desktop").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    Spacer()
                    Button { HUDController.shared.toggleListening() } label: { Label("Ask Alexa", systemImage: "mic.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.top, 8)

                connectionCard
                dictationCard
                speechCard
                tilesCard
                timersAndPlayer
                historyCard
                MadeByFooter()
                    .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await store.pingBridge(); await loadHistory() }
    }

    // MARK: Cards

    private var connectionCard: some View {
        SectionCard(title: "Connection", symbol: "antenna.radiowaves.left.and.right") {
            HStack(spacing: 12) {
                StatusDot(ok: store.bridgeUp && store.state.authenticated, warn: store.bridgeUp && !store.state.authenticated)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.bridgeUp ? (store.state.authenticated ? "Connected to Amazon" : "Bridge running — not logged in") : "Bridge not reachable")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    Text(store.bridgeUp ? "\(store.state.devices.count) Echo device\(store.state.devices.count == 1 ? "" : "s") · \(store.state.smarthome.count) smart-home entities · \(bridge.detail)" : bridge.detail)
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                if store.bridgeUp && !store.state.authenticated {
                    Button("Log in to Amazon") { store.openLogin() }.buttonStyle(PrimaryButtonStyle())
                }
                Button { Task { try? await BridgeClient.refresh(); await store.pingBridge() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if let err = store.state.loginError { Text(err).font(.system(size: 11)).foregroundStyle(Theme.danger) }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Amazon site").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                    Picker("", selection: Binding(get: { store.state.amazonPage ?? "amazon.de" }, set: { store.setRegion($0) })) {
                        ForEach(regions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                HStack(spacing: 6) {
                    Text("Talk to").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                    Picker("", selection: Binding(get: { store.state.defaultDevice ?? "" }, set: { store.setDefaultDevice($0) })) {
                        ForEach(store.state.devices) { d in Text(d.name + (d.online == false ? " (offline)" : "")).tag(d.name) }
                        if store.state.devices.isEmpty { Text("— no devices yet —").tag("") }
                    }
                    .labelsHidden().frame(width: 220)
                }
                Spacer()
            }
            Text("Changing the site logs you out; a wrong site shows 0 devices after login.").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
    }

    private var dictationCard: some View {
        SectionCard(title: "Dictation (Murmur, built in)", symbol: "waveform") {
            DictationPanel()
            RecoveryShortcuts(alexaKey: store.settings.hotkeyKey)
            HStack(spacing: 8) {
                Button { DictationController.shared.presentSetup() } label: { Label("Set up dictation…", systemImage: "checklist") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { NotificationCenter.default.post(name: MetricsModel.openNotification, object: nil) } label: {
                    Label("Metrics…", systemImage: "chart.bar.xaxis")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Text("Hold ⌃⌥Z and talk; release to transcribe and paste at the cursor. Tap Z a second time while ⌃⌥ are still down to lock hands-free (Stop / ⌃⌥Z / Esc end it). ⌃⌥. cycles EN → AR → AUTO. whisper.cpp large-v3-turbo, fully local; audio deleted after every run.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speechCard: some View {
        SectionCard(title: "Push-to-talk", symbol: "mic.fill") {
            HStack(spacing: 16) {
                Picker("Engine", selection: Binding(get: { store.settings.speechEngine }, set: { store.settings.speechEngine = $0; store.saveSettings() })) {
                    Text("Apple (on-device)").tag("apple")
                    Text("whisper.cpp").tag("whisper")
                }
                .frame(width: 260)
                Picker("Language", selection: Binding(get: { store.settings.speechLocale }, set: { store.settings.speechLocale = $0; store.saveSettings() })) {
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("Deutsch").tag("de-DE")
                    Text("العربية (SA)").tag("ar-SA")
                }
                .frame(width: 200)
                Spacer()
            }
            HStack(spacing: 16) {
                Stepper(value: Binding(get: { store.settings.silenceSeconds }, set: { store.settings.silenceSeconds = $0; store.saveSettings() }), in: 0.5...3, step: 0.1) {
                    Text("Stop after \(String(format: "%.1f", store.settings.silenceSeconds)) s of silence").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                HStack(spacing: 6) {
                    Text("Hotkey ⌃⌥").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Picker("", selection: Binding(get: { store.settings.hotkeyKey }, set: { store.settings.hotkeyKey = $0; store.saveSettings() })) {
                        ForEach(["a", "d", "x", "z", "space"], id: \.self) { Text($0 == "space" ? "Space (clashes with input switching)" : $0.uppercased()).tag($0) }
                    }
                    .labelsHidden().frame(width: 90)
                    Text("· applies after relaunch · Murmur keeps ⌃⌥/ and ⌃⌥.").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            Text("Apple recognition falls back to whisper.cpp automatically when it's unavailable. The typed text goes to the Echo you picked above; Alexa answers there, and the reply text comes back here.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tilesCard: some View {
        SectionCard(title: "Tiles", symbol: "square.grid.3x3.fill") {
            LazyVGrid(columns: tileColumns, spacing: 8) {
                ForEach(store.actions.tiles) { t in
                    VStack(spacing: 4) {
                        TileButton(tile: t, entity: store.entity(for: t)) { store.run(t) }
                            .opacity(t.enabled ? 1 : 0.35)
                        HStack(spacing: 6) {
                            Toggle("", isOn: Binding(get: { t.enabled }, set: { v in update(t.id) { $0.enabled = v } }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Theme.accent)
                            Spacer()
                            Button { store.actions.tiles.removeAll { $0.id == t.id }; store.saveActions() } label: { Image(systemName: "trash").font(.system(size: 10)) }
                                .buttonStyle(.plain).foregroundStyle(Theme.text3)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 8) {
                TextField("Label", text: $newLabel).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("What to say, e.g. set ac temperature to 22", text: $newCommand).textFieldStyle(.roundedBorder)
                Button("Add command tile") {
                    let l = newLabel.trimmingCharacters(in: .whitespaces), c = newCommand.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty, !c.isEmpty else { return }
                    store.actions.tiles.append(Tile(id: "t-" + UUID().uuidString.prefix(6), kind: .text, label: l, symbol: "text.bubble.fill", color: "#31D0F2", target: c))
                    store.saveActions(); newLabel = ""; newCommand = ""
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 8) {
                Picker("Device tile", selection: $pickerEntity) {
                    Text("— pick an Alexa device —").tag("")
                    ForEach(store.state.smarthome.sorted { $0.name < $1.name }) { e in Text(e.name).tag(e.id) }
                }
                .frame(width: 320)
                Button("Add device tile") {
                    guard let e = store.state.smarthome.first(where: { $0.id == pickerEntity }) else { return }
                    store.actions.tiles.append(Tile(id: "e-" + UUID().uuidString.prefix(6), kind: .entity, label: e.name, symbol: "power", color: "#31D0F2", target: e.id))
                    store.saveActions(); pickerEntity = ""
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Text("Device tiles match by name (AC, TV, Neon…) once the bridge has loaded your smart home.").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
        }
    }

    private var timersAndPlayer: some View {
        HStack(alignment: .top, spacing: 16) {
            SectionCard(title: "Timers & reminders", symbol: "timer") {
                if store.state.notifications.isEmpty {
                    Text("Nothing running.").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                ForEach(store.state.notifications, id: \.uid) { n in
                    HStack {
                        Text(n.label?.isEmpty == false ? n.label! : n.type).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(n.device ?? "").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        Spacer()
                        if let d = n.endDate {
                            if n.type == "Timer" { Text(d, style: .timer).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.gold) }
                            else { Text(d, style: .time).font(.system(size: 12)).foregroundStyle(Theme.text2) }
                        }
                    }
                }
            }
            SectionCard(title: "Playing on \(store.state.defaultDevice ?? "Echo")", symbol: "hifispeaker.fill") {
                if let p = store.state.player, p.title != nil {
                    Text(p.title ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    Text([p.artist, p.album, p.provider].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    HStack(spacing: 10) {
                        Button { Task { try? await BridgeClient.player("previous") } } label: { Image(systemName: "backward.fill") }
                        Button { Task { try? await BridgeClient.player(p.isPlaying ? "pause" : "play") } } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill") }
                        Button { Task { try? await BridgeClient.player("next") } } label: { Image(systemName: "forward.fill") }
                        Spacer()
                        Text("vol \(Int(p.volume ?? 0))").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Text("Idle.").font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
            }
        }
    }

    private var historyCard: some View {
        SectionCard(title: "Recent conversations", symbol: "text.bubble.fill") {
            if history.isEmpty {
                Text("Nothing yet — press Ask Alexa.").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            ForEach(Array(history.prefix(12).enumerated()), id: \.offset) { _, ex in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("You: \(ex.utterance ?? "")").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(ex.date, style: .time).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                    Text(ex.response ?? "(no reply text)").font(.system(size: 12)).foregroundStyle(ex.response == nil ? Theme.text3 : Theme.text2)
                }
                .padding(.vertical, 4)
                Divider().overlay(Color.white.opacity(0.06))
            }
            Button("Reload history") { Task { await loadHistory() } }.buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: helpers

    private func update(_ id: String, _ body: (inout Tile) -> Void) {
        if let i = store.actions.tiles.firstIndex(where: { $0.id == id }) {
            body(&store.actions.tiles[i])
            store.saveActions()
        }
    }

    private func loadHistory() async {
        guard let rows = try? await BridgeClient.requestArray("GET", "history?minutes=720") else { return }
        history = rows.compactMap { r in
            AlexaExchange(utterance: r["utterance"] as? String, response: r["response"] as? String, at: r["at"] as? Double, device: r["device"] as? String, note: nil)
        }
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
