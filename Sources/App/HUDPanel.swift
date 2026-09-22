import AppKit
import SwiftUI

/// Floating, non-activating panel that shows the push-to-talk state near the top of the screen.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private let ptt: PushToTalk

    private init() {
        ptt = PushToTalk()
        ptt.onPhaseChange = { [weak self] phase in
            Task { @MainActor in self?.phaseChanged(phase) }
        }
    }

    var session: PushToTalk { ptt }

    func toggleListening() {
        ptt.toggle()
    }

    private func phaseChanged(_ phase: PushToTalk.Phase) {
        switch phase {
        case .listening, .transcribing, .sending, .waiting:
            show()
            hideWork?.cancel()
        case .done:
            show()
            scheduleHide(after: 7)
        case .failed:
            show()
            scheduleHide(after: 4)
        case .idle:
            break
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: HUDView(ptt: ptt, onCancel: { [weak self] in self?.ptt.cancel(); self?.hide() }))
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            let w: CGFloat = 420, h: CGFloat = 150
            panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 12, width: w, height: h), display: true)
        }
        panel.orderFrontRegardless()
    }

    func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct HUDView: View {
    @ObservedObject var ptt: PushToTalk
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(ptt.phase == .listening ? Theme.accent : Color.white.opacity(0.1)).frame(width: 30, height: 30)
                    Image(systemName: icon).font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ptt.phase == .listening ? Color.black.opacity(0.85) : Theme.text)
                        .symbolEffect(.pulse, isActive: ptt.phase == .listening || ptt.phase == .waiting)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer()
                if ptt.phase == .listening {
                    LevelBars(level: ptt.level).frame(width: 90, height: 22)
                }
                Button { onCancel() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
            }
            if !ptt.transcript.isEmpty || ptt.phase == .listening {
                Text(ptt.transcript.isEmpty ? "…" : "“\(ptt.transcript)”")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let ex = ptt.exchange, ptt.phase == .done || ptt.phase == .waiting {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent).padding(.top, 2)
                    Text(ex.response ?? ex.note ?? (ptt.phase == .waiting ? "Waiting for Alexa…" : "…"))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ex.response == nil ? Theme.text3 : Theme.text)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: "#17151A").opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(ptt.phase == .listening ? 0.7 : 0.2), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(8)
        .animation(.easeOut(duration: 0.18), value: ptt.phase)
    }

    private var icon: String {
        switch ptt.phase {
        case .listening: return "mic.fill"
        case .transcribing: return "text.viewfinder"
        case .sending, .waiting: return "paperplane.fill"
        case .done: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "mic"
        }
    }

    private var title: String {
        switch ptt.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing (whisper)…"
        case .sending: return "Sending to Echo…"
        case .waiting: return "Alexa is thinking…"
        case .done: return "Alexa"
        case .failed(let why): return why
        case .idle: return "Ask Alexa"
        }
    }

    private var subtitle: String {
        switch ptt.phase {
        case .listening: return "Talk normally — stops on its own when you pause · \(ptt.engineUsed)"
        case .done: return ptt.exchange?.device.map { "answered on \($0)" } ?? ""
        default: return ""
        }
    }
}

struct LevelBars: View {
    var level: Float
    var body: some View {
        TimelineView(.animation) { t in
            let phase = t.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<14, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(phase * 9 + Double(i) * 0.9)
                    let h = 4 + CGFloat(level) * 18 * CGFloat(wobble)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 4, height: max(3, h))
                }
            }
        }
    }
}
