import SwiftUI

@main
struct DeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DeckStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Deck", id: "main") {
            DashboardView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .frame(minWidth: 820, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 720)
    }
}

/// Always-alive label view: the place that can open the dashboard window from a URL/notification.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    private static let glyph: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuGlyph@2x", withExtension: "png"), let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 22, height: 11)
        img.isTemplate = true
        return img
    }()
    var body: some View {
        Group {
            if let g = MenuBarLabel.glyph { Image(nsImage: g) } else { Image(systemName: "waveform.and.mic") }
        }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("com.yahya.deck.openMain"))) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
