import AVFoundation
import Combine
import Murmur
import Speech
import SwiftUI

/// "Set up dictation": every permission and file dictation needs, with live status and the one
/// action that fixes each. Opens on launch when dictation cannot work; re-run it from the
/// Dashboard or the menu.
struct SetupView: View {
    @ObservedObject private var d = DictationController.shared.state
    @StateObject private var live = LiveSetupStatus()
    private var status: SetupStatus { live.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up dictation").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                Text(status.ready ? "All set. Hold ⌃⌥Z anywhere and talk." : "Dictation needs the items below. This updates as you change them.")
                    .font(.system(size: 12)).foregroundStyle(status.ready ? Theme.success : Theme.text3)
            }

            row("Microphone", "Hears you only while ⌃⌥Z is held or locked.", state: status.microphone) {
                switch status.microphone {
                case .missing: Button("Allow") { AVCaptureDevice.requestAccess(for: .audio) { _ in } }.buttonStyle(PrimaryButtonStyle())
                case .blocked: Button("Open Settings") { Permissions.openMicrophoneSettings() }.buttonStyle(PrimaryButtonStyle())
                case .ok: EmptyView()
                }
            }
            row("Accessibility", "Lets the ⌃⌥Z chord work in every app and pastes the text at the cursor.", state: status.accessibility) {
                if status.accessibility != .ok {
                    Button("Open Settings") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                        DictationController.shared.pollForPermission()
                    }.buttonStyle(PrimaryButtonStyle())
                }
            }
            row("Speech model", status.modelDetail, state: status.model) {
                if status.model == .ok {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: DictationPaths.model)]) }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Open folder") {
                        let dir = URL(fileURLWithPath: DictationPaths.model).deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }.buttonStyle(PrimaryButtonStyle())
                }
            }
            row("Speech Recognition", "Optional. Only Ask Alexa uses it; dictation runs on whisper.", state: status.speech, optional: true) {
                switch status.speech {
                case .missing: Button("Allow") { SFSpeechRecognizer.requestAuthorization { _ in } }.buttonStyle(SecondaryButtonStyle())
                case .blocked: Button("Open Settings") { SetupStatus.openSpeechSettings() }.buttonStyle(SecondaryButtonStyle())
                case .ok: EmptyView()
                }
            }

            HStack {
                Text(d.armed ? "Dictation chord armed" : (status.accessibility == .ok ? "Arming the dictation chord…" : "Dictation chord waiting for Accessibility"))
                    .font(.system(size: 11)).foregroundStyle(d.armed ? Theme.success : Theme.text3)
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }.buttonStyle(status.ready ? AnyButtonStyleBox.primary : AnyButtonStyleBox.secondary)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.background.ignoresSafeArea())
    }

    private func row<Actions: View>(_ title: String, _ detail: String, state: SetupStatus.State, optional: Bool = false,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state == .ok ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "exclamationmark.circle.fill"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state == .ok ? Theme.success : (optional ? Theme.text3 : Theme.gold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
        .padding(12).card(tint: state == .ok || optional ? nil : Theme.gold, radius: 12)
    }
}

/// A ButtonStyle chosen at runtime (SwiftUI wants a concrete style per call site).
enum AnyButtonStyleBox: ButtonStyle {
    case primary, secondary
    func makeBody(configuration: Configuration) -> some View {
        Group {
            switch self {
            case .primary: PrimaryButtonStyle().makeBody(configuration: configuration)
            case .secondary: SecondaryButtonStyle().makeBody(configuration: configuration)
            }
        }
    }
}

/// Re-reads the status every second while the window is open. (An ObservableObject rather than
/// @State: the State macro has no plugin outside Xcode.)
final class LiveSetupStatus: ObservableObject {
    @Published var status = SetupStatus.read()
    private var timer: AnyCancellable?
    init() {
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.status = SetupStatus.read() }
    }
}

struct SetupStatus {
    enum State { case ok, missing, blocked }

    var microphone: State
    var accessibility: State
    var model: State
    var speech: State
    var modelDetail: String

    /// Dictation can run: the optional Speech Recognition row doesn't count.
    var ready: Bool { microphone == .ok && accessibility == .ok && model == .ok }

    static func read() -> SetupStatus {
        let mic: State = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .ok
            case .notDetermined: return .missing
            default: return .blocked
            }
        }()
        let speech: State = {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .ok
            case .notDetermined: return .missing
            default: return .blocked
            }
        }()
        let path = DictationPaths.model
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        let name = URL(fileURLWithPath: path).lastPathComponent
        let detail = size.map { "\(name), \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)), runs on this Mac." }
            ?? "Not found at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). The Yaya Suite installer downloads it, or put a whisper model there."
        return SetupStatus(microphone: mic, accessibility: Permissions.accessibility ? .ok : .missing,
                           model: size == nil ? .missing : .ok, speech: speech, modelDetail: detail)
    }

    static func openSpeechSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
    }

    /// Posted to open the setup window from anywhere in the app.
    static let openNotification = Notification.Name("com.yahya.deck.openSetup")
}
