import SwiftUI
import Murmur

struct MenuBarView: View {
    @EnvironmentObject var store: DeckStore
    @Environment(\.openWindow) private var openWindow
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { HUDController.shared.toggleListening() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold))
                        Text("Ask Alexa").font(.system(size: 13, weight: .bold, design: .rounded))
                        Text("⌃⌥\(store.settings.hotkeyKey.uppercased())").font(.system(size: 10, weight: .semibold)).opacity(0.7)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(LinearGradient(colors: [Color(hex: "#E9906E"), Theme.accent], startPoint: .leading, endPoint: .trailing)))
                    .foregroundStyle(Color.black.opacity(0.85))
                }
                .buttonStyle(.plain)
                StatusDot(ok: store.bridgeUp && store.state.authenticated, warn: store.bridgeUp && !store.state.authenticated)
                    .help(statusText)
            }

            if let ex = store.state.lastExchange {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You: \(ex.utterance ?? "")").font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                    Text(ex.response ?? ex.note ?? "…").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                }
                .padding(10).card(radius: 10)
            } else if !store.state.authenticated {
                HStack {
                    Text(store.bridgeUp ? "Not logged in to Amazon yet." : "Bridge starting…").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    Spacer()
                    if store.bridgeUp { Button("Log in") { store.openLogin() }.buttonStyle(PrimaryButtonStyle()) }
                }
                .padding(10).card(radius: 10)
            }

            let tiles = store.actions.tiles.filter(\.enabled)
            if !tiles.isEmpty {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(tiles) { t in
                        TileButton(tile: t, entity: store.entity(for: t), compact: true) { store.run(t) }
                            .opacity(store.busyTile == t.id ? 0.5 : 1)
                    }
                }
            }

            if !store.state.notifications.isEmpty {
                VStack(spacing: 4) {
                    ForEach(store.state.notifications.prefix(3), id: \.uid) { n in
                        HStack(spacing: 8) {
                            Image(systemName: n.type == "Timer" ? "timer" : (n.type == "Alarm" ? "alarm.fill" : "bell.fill"))
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.gold)
                            Text(n.label?.isEmpty == false ? n.label! : n.type).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            if let d = n.endDate {
                                if n.type == "Timer" { Text(d, style: .timer).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text) }
                                else { Text(d, style: .time).font(.system(size: 11.5)).foregroundStyle(Theme.text2) }
                            }
                        }
                    }
                }
                .padding(10).card(radius: 10)
            }

            if let p = store.state.player, p.title != nil {
                HStack(spacing: 8) {
                    Image(systemName: "hifispeaker.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title ?? "").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text([p.artist, p.device].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer()
                    Button { Task { try? await BridgeClient.player("previous") } } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
                    Button { Task { try? await BridgeClient.player(p.isPlaying ? "pause" : "play") } } label: { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
                    Button { Task { try? await BridgeClient.player("next") } } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
                }
                .foregroundStyle(Theme.text)
                .padding(10).card(radius: 10)
            }

            DictationPanel()

            if let t = store.toast {
                Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
            }

            HStack {
                Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: { Label("Open Deck", systemImage: "macwindow") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { Task { try? await BridgeClient.refresh(); await store.pingBridge() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle()).help("Refresh from Alexa")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(Theme.text3).font(.system(size: 11))
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.background)
        .onAppear { Task { await store.pingBridge() } }
    }

    private var statusText: String {
        if !store.bridgeUp { return "Bridge not running" }
        return store.state.authenticated ? "Connected · \(store.state.devices.count) Echo devices" : "Log in to Amazon"
    }
}


/// Dictation (ex-Murmur) status and controls inside the menu bar panel.
struct DictationPanel: View {
    @ObservedObject private var d = DictationController.shared.state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(DT.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.armed ? "Dictation · hold ⌃⌥Z" : "Dictation needs Accessibility")
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    Text(d.armed ? "double-tap to lock hands-free · ⌃⌥. language · \(d.totalWords.formatted()) words so far"
                                 : "Turn Deck on under Privacy → Accessibility")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(2)
                }
                Spacer()
                if !d.armed {
                    Button("Fix") { DictationController.shared.presentSetup() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            HStack(spacing: 6) {
                ForEach(Lang.allCases, id: \.self) { l in
                    Button { DictationController.shared.setLang(l) } label: {
                        Text(l.label).font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(d.lang == l ? DT.accent : Color.white.opacity(0.08)))
                            .foregroundStyle(d.lang == l ? Color.black.opacity(0.85) : Theme.text2)
                    }
                    .buttonStyle(.plain)
                    .help(l.long)
                }
                Spacer()
                Toggle("Paste", isOn: Binding(get: { d.autoPaste }, set: { DictationController.shared.setAutoPaste($0) }))
                    .toggleStyle(.switch).controlSize(.mini).tint(DT.accent).font(.system(size: 10.5)).foregroundStyle(Theme.text2)
                Toggle("Sounds", isOn: Binding(get: { d.sounds }, set: { DictationController.shared.setSounds($0) }))
                    .toggleStyle(.switch).controlSize(.mini).tint(DT.accent).font(.system(size: 10.5)).foregroundStyle(Theme.text2)
            }
        }
        .padding(10).card(tint: d.armed ? nil : Theme.gold, radius: 10)
    }
}

/// ⌃⌥<letter> shortcuts that paste or copy the last dictation again, for 24 hours.
struct RecoveryShortcuts: View {
    let alexaKey: String
    @ObservedObject private var d = DictationController.shared.state
    private static let choices = ["v", "c", "b", "g", "l", "n", "p", "r", "y"]

    var body: some View {
        HStack(spacing: 14) {
            picker("Paste last", selection: d.pasteLastKey, taken: d.copyLastKey) { DictationController.shared.setPasteLastKey($0) }
            picker("Copy last", selection: d.copyLastKey, taken: d.pasteLastKey) { DictationController.shared.setCopyLastKey($0) }
            Text("re-use the last dictation for 24 hours").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer()
        }
        HStack(spacing: 6) {
            Text("Speech model").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Picker("", selection: Binding(get: { d.model }, set: { DictationController.shared.setModel($0) })) {
                ForEach(SpeechModel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Text(d.model == .fast ? "large-v3-turbo · text about half a second after you let go"
                                  : "large-v3 · fewer mistakes in Arabic and mixed speech · text about twice as slow")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer()
        }
        HStack(spacing: 6) {
            Text("Keep the speech model loaded for").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Picker("", selection: Binding(get: { d.keepModelMinutes }, set: { DictationController.shared.setKeepModelMinutes($0) })) {
                ForEach([5, 10, 30, 60, 0], id: \.self) { Text($0 == 0 ? "until quit" : "\($0) min").tag($0) }
            }
            .labelsHidden().frame(width: 96)
            Text("after the last dictation · about \(d.model.loadedGB) GB while loaded").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer()
        }
        HStack(spacing: 6) {
            Toggle("Keep recordings for 24 hours", isOn: Binding(get: { d.keepRecordings }, set: { DictationController.shared.setKeepRecordings($0) }))
                .toggleStyle(.switch).controlSize(.mini).tint(DT.accent).font(.system(size: 11)).foregroundStyle(Theme.text2)
            Text("last 20, on this Mac only, to fix dictations that came out wrong · off deletes them").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer()
        }
    }

    private func picker(_ title: String, selection: String, taken: String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            Text("\(title) ⌃⌥").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Picker("", selection: Binding(get: { selection }, set: set)) {
                ForEach(Self.choices.filter { $0 == selection || ($0 != taken && $0 != alexaKey.lowercased()) }, id: \.self) {
                    Text($0.uppercased()).tag($0)
                }
            }
            .labelsHidden().frame(width: 56)
        }
    }
}
