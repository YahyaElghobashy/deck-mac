import WidgetKit
import SwiftUI
import AppIntents

struct DeckEntry: TimelineEntry {
    let date: Date
    let state: AlexaState
    let tiles: [Tile]
}

struct DeckProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeckEntry {
        DeckEntry(date: Date(), state: AlexaState(), tiles: DeckActions.defaults)
    }
    func getSnapshot(in context: Context, completion: @escaping (DeckEntry) -> Void) {
        completion(DeckEntry(date: Date(), state: AlexaState.load(), tiles: DeckActions.load().tiles.filter(\.enabled)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DeckEntry>) -> Void) {
        DebugLog.write("widget timeline \(context.family)")
        let entry = DeckEntry(date: Date(), state: AlexaState.load(), tiles: DeckActions.load().tiles.filter(\.enabled))
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct DeckAlexaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DeckPaths.widgetKind, provider: DeckProvider()) { entry in
            DeckWidgetView(entry: entry)
        }
        .configurationDisplayName("Deck · Alexa")
        .description("Push-to-talk to Alexa, one-tap devices and commands, live timers.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct DeckWidgetBundle: WidgetBundle {
    init() { DebugLog.write("widget process up: \(CommandLine.arguments.dropFirst().joined(separator: " ").prefix(120))") }
    var body: some Widget { DeckAlexaWidget() }
}

// MARK: - Pieces

private let listenURL = URL(string: "deck://listen")!

/// Widget buttons open deck:// links that the app handles. Interactive `Button(intent:)` needs an
/// Apple Team ID in the code signature (linkd rejects unsigned bundles as invalid clients), links do
/// not, and Deck is a menu-bar app so nothing comes to the front.
enum DeckLinks {
    static func action(kind: String, target: String) -> URL {
        var c = URLComponents()
        c.scheme = DeckPaths.urlScheme
        c.host = "action"
        c.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "target", value: target)]
        return c.url ?? openURL
    }
}
private let openURL = URL(string: "deck://open")!

struct MicButton: View {
    var big = false
    var body: some View {
        Link(destination: listenURL) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").font(.system(size: big ? 15 : 12, weight: .heavy))
                Text(big ? "Ask Alexa" : "Ask").font(.system(size: big ? 13 : 11.5, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, big ? 14 : 10).padding(.vertical, big ? 9 : 6)
            .background(Capsule().fill(LinearGradient(colors: [Color(hex: "#E9906E"), Theme.accent], startPoint: .leading, endPoint: .trailing)))
        }
    }
}

struct ExchangeView: View {
    let ex: AlexaExchange?
    var lines = 2
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let ex {
                Text("You: \(ex.utterance ?? "")").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Text(ex.response ?? ex.note ?? "…").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(lines)
            } else {
                Text("Tap Ask, talk, done.").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

struct WTile: View {
    let tile: Tile
    let entity: SmartEntity?
    var body: some View {
        let color = Color(hex: tile.color)
        let on = entity?.isOn ?? false
        let kind = tile.kind == .entity ? "entity-toggle" : (tile.kind == .routine ? "routine" : "text")
        let target = tile.kind == .entity ? (entity?.id ?? tile.target) : tile.target
        Link(destination: DeckLinks.action(kind: kind, target: target)) {
            HStack(spacing: 6) {
                Image(systemName: tile.symbol).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(on ? Color.black.opacity(0.85) : color)
                Text(tile.label).font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Color.black.opacity(0.85) : .white).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? color : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(on ? 1 : 0.35), lineWidth: 1))
            .opacity(tile.kind == .entity && entity == nil ? 0.4 : 1)
        }
    }
}

struct TimerRows: View {
    let items: [AlexaNotification]
    var max = 3
    var body: some View {
        VStack(spacing: 3) {
            ForEach(items.prefix(max), id: \.uid) { n in
                HStack(spacing: 6) {
                    Image(systemName: n.type == "Timer" ? "timer" : (n.type == "Alarm" ? "alarm.fill" : "bell.fill"))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.gold)
                    Text(n.label?.isEmpty == false ? n.label! : n.type).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    if let d = n.endDate {
                        if n.type == "Timer" { Text(d, style: .timer).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white) }
                        else { Text(d, style: .time).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7)) }
                    }
                }
            }
        }
    }
}

struct PlayerRow: View {
    let p: AlexaPlayer
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hifispeaker.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            Text(p.title ?? "").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Link(destination: DeckLinks.action(kind: "player", target: "previous")) { Image(systemName: "backward.fill") }
            Link(destination: DeckLinks.action(kind: "player", target: p.isPlaying ? "pause" : "play")) { Image(systemName: p.isPlaying ? "pause.fill" : "play.fill") }
            Link(destination: DeckLinks.action(kind: "player", target: "next")) { Image(systemName: "forward.fill") }
        }
        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
    }
}

// MARK: - Families

struct DeckWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeckEntry

    private func entity(_ t: Tile) -> SmartEntity? {
        guard t.kind == .entity else { return nil }
        return entry.state.smarthome.first { $0.id == t.target } ?? entry.state.entity(named: t.target)
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            case .systemExtraLarge: extraLarge
            default: large
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                LinearGradient(colors: [Color(hex: "#17151A"), Color(hex: "#221F27")], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.accent.opacity(0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            MicButton(big: true)
            ExchangeView(ex: entry.state.lastExchange, lines: 2)
            Spacer(minLength: 0)
            if !entry.state.authenticated {
                Link(destination: openURL) { Chip(text: "log in", systemImage: "person.crop.circle.badge.exclamationmark", color: Theme.gold) }
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicButton(big: true)
            ExchangeView(ex: entry.state.lastExchange, lines: 3)
            Spacer(minLength: 0)
            let two = Array(entry.tiles.prefix(2))
            HStack(spacing: 4) { ForEach(two) { WTile(tile: $0, entity: entity($0)) } }
        }
    }

    private var medium: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                MicButton(big: true)
                ExchangeView(ex: entry.state.lastExchange, lines: 3)
                Spacer(minLength: 0)
                if let n = entry.state.notifications.first { TimerRows(items: [n], max: 1) }
            }
            .frame(width: 150, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            let six = Array(entry.tiles.prefix(6))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(six) { WTile(tile: $0, entity: entity($0)) }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            let nine = Array(entry.tiles.prefix(9))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                ForEach(nine) { WTile(tile: $0, entity: entity($0)) }
            }
            Spacer(minLength: 0)
            if !entry.state.notifications.isEmpty { TimerRows(items: entry.state.notifications, max: 2) }
            if let p = entry.state.player, p.title != nil { PlayerRow(p: p) }
        }
    }

    private var extraLarge: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 14) {
                let tiles = Array(entry.tiles.prefix(18))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(tiles) { WTile(tile: $0, entity: entity($0)) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Timers").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    if entry.state.notifications.isEmpty { Text("none").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)) }
                    TimerRows(items: entry.state.notifications, max: 5)
                    if let p = entry.state.player, p.title != nil {
                        Text("Playing").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        PlayerRow(p: p)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 200)
            }
        }
    }
}
