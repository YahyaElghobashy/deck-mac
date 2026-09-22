import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        var r = 1.0, g = 0.5, b = 0.1
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Dark, game-y palette shared by the app, the menu bar panel and the widget.
enum Theme {
    static let bgTop = Color(hex: "#17151A")
    static let bgBottom = Color(hex: "#221F27")
    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.09)
    static let text = Color(hex: "#EFEAE2")
    static let text2 = Color(hex: "#EFEAE2").opacity(0.62)
    static let text3 = Color(hex: "#EFEAE2").opacity(0.40)
    static let success = Color(hex: "#6BB857")
    static let danger = Color(hex: "#E36166")
    static let freeze = Color(hex: "#7DD3FC")
    static let accent = Color(hex: "#D9724E")
    static let gold = Color(hex: "#D99E47")
    static let stone = Color(hex: "#7C7480")
    static let sand = Color(hex: "#EFEAE2")

    static var background: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
    }

    /// The flame gets hotter as the streak grows: grey → orange → red-pink → violet-blue.
    static func flameColors(streak: Int) -> [Color] {
        switch streak {
        case 0:        return [Color.white.opacity(0.35), Color.white.opacity(0.2)]
        case 1...2:    return [Color(hex: "#FFB020"), Color(hex: "#FF7A1A")]
        case 3...6:    return [Color(hex: "#FFC53D"), Color(hex: "#FF5A36")]
        case 7...29:   return [Color(hex: "#FFD166"), Color(hex: "#FF3D7F")]
        case 30...99:  return [Color(hex: "#FFE066"), Color(hex: "#FF2D95"), Color(hex: "#8B5CF6")]
        default:       return [Color(hex: "#FFFFFF"), Color(hex: "#7DD3FC"), Color(hex: "#8B5CF6")]
        }
    }

    static func flameGradient(streak: Int) -> LinearGradient {
        LinearGradient(colors: flameColors(streak: streak), startPoint: .bottom, endPoint: .top)
    }

    static func gameGradient(_ hex: String) -> LinearGradient {
        let c = Color(hex: hex)
        return LinearGradient(colors: [c.opacity(0.95), c.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
