import AppKit
import SwiftUI
import Murmur
import Carbon
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: DeckPaths.dir, withIntermediateDirectories: true)
        if let i = CommandLine.arguments.firstIndex(of: "--render-setup"), i + 1 < CommandLine.arguments.count {
            renderSetup(to: CommandLine.arguments[i + 1])   // a PNG of "Set up dictation", for checks; then quits
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-dictation-settings"), i + 1 < CommandLine.arguments.count {
            renderDictationSettings(to: CommandLine.arguments[i + 1])   // the Dashboard's dictation settings rows
        }
        SuiteFlags.handle(appName: "Deck")
        DebugLog.write("Deck launched")
        Task { @MainActor in BridgeSupervisor.shared.start() }

        // Widget mic button (intent) and menu bar both land here.
        DistributedNotificationCenter.default().addObserver(forName: DeckPaths.listenNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HUDController.shared.toggleListening() }
        }
        NotificationCenter.default.addObserver(forName: DeckPaths.listenNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HUDController.shared.toggleListening() }
        }
        registerHotKey()
        WidgetCenter.shared.reloadAllTimelines()
        Task { @MainActor in DictationController.shared.start() }
    }

    @MainActor private func renderSetup(to path: String) -> Never {
        render(SetupView(), to: path)
    }

    @MainActor private func renderDictationSettings(to path: String) -> Never {
        render(VStack(alignment: .leading, spacing: 8) { RecoveryShortcuts(alexaKey: "A") }
            .padding(14).frame(width: 760).background(Color(white: 0.12)), to: path)
    }

    @MainActor private func render<V: View>(_ view: V, to path: String) -> Never {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Everything here runs synchronously: the process exits as soon as this returns, so work
        // scheduled in a Task never runs. That left the Node bridge running after every quit, and
        // a whisper model still in memory when ggml's Metal device is torn down at exit crashes.
        MainActor.assumeIsolated {
            BridgeSupervisor.shared.stop()
            DictationController.shared.stop()   // frees the whisper model too
        }
    }

    /// deck://listen · deck://open
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            switch u.host?.lowercased() {
            case "listen":
                Task { @MainActor in HUDController.shared.toggleListening() }
            case "action":
                Task { @MainActor in await WidgetActions.handle(u) }
            default:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: Notification.Name("com.yahya.deck.openMain"), object: nil)
            }
        }
    }

    // ⌃⌥<letter> → push-to-talk (default A). Carbon hot keys need no Accessibility permission.
    // Not Space: ⌃⌥Space is macOS's "next input source" (ABC ⇄ Arabic here); Murmur owns ⌃⌥/ and ⌃⌥.
    private static let letterCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "space": kVK_Space,
    ]

    private func registerHotKey() {
        let settings = DeckSettings.load()
        guard settings.hotkeyEnabled else { return }
        let code = AppDelegate.letterCodes[settings.hotkeyKey.lowercased()] ?? kVK_ANSI_A
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HUDController.shared.toggleListening() }
            return noErr
        }, 1, &eventType, nil, nil)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4445434B), id: 1) // 'DECK'
        let status = RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        DebugLog.write("hotkey ⌃⌥\(settings.hotkeyKey.uppercased()) registered (status \(status))")
    }
}
