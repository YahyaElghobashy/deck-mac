import SwiftUI

struct CardBackground: ViewModifier {
    var hover: Bool = false
    var tint: Color? = nil
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(tint?.opacity(0.4) ?? Theme.stroke, lineWidth: 1))
    }
}
extension View {
    func card(hover: Bool = false, tint: Color? = nil, radius: CGFloat = 16) -> some View {
        modifier(CardBackground(hover: hover, tint: tint, radius: radius))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(LinearGradient(colors: [Color(hex: "#E9906E"), Color(hex: "#D9724E")], startPoint: .leading, endPoint: .trailing)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct StatusDot: View {
    var ok: Bool
    var warn: Bool = false
    var body: some View {
        let c: Color = ok ? Theme.success : (warn ? Theme.gold : Theme.danger)
        Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.8), radius: 4)
    }
}

/// `@State` is an Xcode-only macro in this SDK; wrap the plain State struct instead.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>
    init(wrappedValue: Value) { storage = SwiftUI.State(wrappedValue: wrappedValue) }
    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { storage.projectedValue }
}

/// A smart-home / command tile shared by the menu bar panel and the dashboard.
struct TileButton: View {
    let tile: Tile
    let entity: SmartEntity?
    var compact = false
    let action: () -> Void
    @Local private var hover = false

    var body: some View {
        let color = Color(hex: tile.color)
        let on = entity?.isOn ?? false
        let live = tile.kind != .entity || entity != nil
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                HStack {
                    Image(systemName: tile.symbol).font(.system(size: compact ? 13 : 15, weight: .bold))
                        .foregroundStyle(on ? Color.black.opacity(0.85) : color)
                    Spacer()
                    if tile.kind == .entity {
                        Circle().fill(on ? Color.black.opacity(0.6) : Color.white.opacity(0.18)).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "text.bubble").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                    }
                }
                Text(tile.label).font(.system(size: compact ? 11.5 : 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.text).lineLimit(1)
                if !compact {
                    Text(tile.kind == .entity ? (live ? (on ? "On" : "Off") : "not found") : "tap to send")
                        .font(.system(size: 10)).foregroundStyle(on ? Color.black.opacity(0.6) : Theme.text3).lineLimit(1)
                }
            }
            .padding(compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? color : Color.white.opacity(hover ? 0.1 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? color : color.opacity(hover ? 0.6 : 0.25), lineWidth: 1))
            .opacity(live ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tile.kind == .entity ? "Toggle \(tile.label)" : "Say to Alexa: “\(tile.target)”")
    }
}
