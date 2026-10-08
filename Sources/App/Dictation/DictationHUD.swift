import AppKit
import SwiftUI
import Murmur

/// Dictation bubble tokens: Deck's navy card, Murmur's ember kept as the "your voice" colour.
enum DT {
    static let radius: CGFloat = 16
    static let card   = Color(hex: "#17151A")
    static let sand   = Color(hex: "#EFEAE2")
    static let accent = Color(hex: "#D9724E")
    static let stroke = sand.opacity(0.10)
    static let fg = sand
    static let muted = sand.opacity(0.55)
    static let faint = sand.opacity(0.38)
    static let good = Color(red: 0.42, green: 0.72, blue: 0.34)
    static let bad = Color(red: 0.89, green: 0.38, blue: 0.40)
    static let warn = Color(red: 0.85, green: 0.62, blue: 0.28)
    static func mono(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: s, weight: w, design: .monospaced) }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: s, weight: w, design: .rounded) }
}

/// The Murmur mark, leading every non-recording bubble state.
struct BrandMark: View {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "HudMark@2x", withExtension: "png"), let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: img.size.width / 2, height: img.size.height / 2)
        return img
    }()
    var body: some View {
        if let img = Self.image { Image(nsImage: img).padding(.trailing, 1).accessibilityLabel("Deck") }
    }
}

private struct Pill: View {
    let text: String
    var tone: Color = DT.faint
    var body: some View {
        Text(text).font(DT.mono(9.5, .semibold)).tracking(0.6).foregroundColor(tone)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tone.opacity(0.13)))
    }
}

/// The recording light: an ember disc pulsing, three crescents drifting like air carrying sound.
private struct AnimatedMark: View {
    var paused: Bool
    private struct HalfDisc: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addArc(center: CGPoint(x: rect.minX, y: rect.midY), radius: rect.height / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.closeSubpath()
            return p
        }
    }
    private func pulse(_ t: Double) -> CGFloat { paused ? 1 : CGFloat(1.0 + 0.10 * (0.5 + 0.5 * sin(t * 2 * Double.pi / 1.2))) }
    private func drift(_ t: Double, _ i: Int) -> CGFloat { paused ? 0 : CGFloat(sin(t * 2 * Double.pi / (1.5 + Double(i) * 0.25) + Double(i) * 1.9) * 1.3) }
    private static let heights: [CGFloat] = [11, 8.5, 6]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                Circle().fill(DT.accent).frame(width: 13, height: 13).scaleEffect(pulse(t))
                    .shadow(color: DT.accent.opacity(paused ? 0 : 0.5), radius: 3.5 * pulse(t))
                ForEach(0..<3, id: \.self) { i in
                    HalfDisc().fill(DT.sand.opacity(paused ? 0.4 : 0.92))
                        .frame(width: Self.heights[i] / 2 + 1.5, height: Self.heights[i])
                        .offset(x: drift(t, i))
                }
            }
            .opacity(paused ? 0.75 : 1)
        }
        .frame(height: 16)
    }
}

private struct LiveMeter: View {
    let levels: [Float]
    var dimmed = false
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, v in
                Capsule(style: .continuous).fill(DT.accent.opacity(dimmed ? 0.22 : 0.35 + 0.65 * Double(min(1, v))))
                    .frame(width: 2.5, height: max(2.5, CGFloat(min(1, v)) * 22))
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: levels)
    }
}

private struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

private struct CtlButton: View {
    let system: String
    let label: String
    var tone: Color = DT.fg
    let action: () -> Void
    @Local private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system).font(.system(size: 9.5, weight: .bold))
                if !label.isEmpty { Text(label).font(DT.ui(11, .semibold)).fixedSize() }
            }
            .foregroundColor(tone)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tone.opacity(hovering ? 0.22 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tone.opacity(hovering ? 0.35 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
    }
}

private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            Circle().trim(from: 0, to: 0.72)
                .stroke(DT.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.75) / 0.75 * 360))
        }
    }
}

struct DictationHUDView: View {
    @ObservedObject var state: DictationState

    var body: some View {
        HStack(spacing: 11) {
            if case .recording = state.phase {} else { BrandMark() }
            content
        }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(minWidth: 190)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DT.radius, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DT.radius, style: .continuous).fill(DT.card.opacity(0.86))
                    RoundedRectangle(cornerRadius: DT.radius, style: .continuous).strokeBorder(DT.stroke, lineWidth: 1)
                }
            )
            .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.phase)
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .recording(let locked, let paused):
            AnimatedMark(paused: paused)
            LiveMeter(levels: state.levels, dimmed: paused)
            VStack(alignment: .leading, spacing: 2) {
                Text(paused ? "Paused" : (locked ? "Locked on" : "Listening")).font(DT.ui(13, .semibold)).foregroundColor(DT.fg)
                Text(paused ? "Resume or stop when ready" : (locked ? "Hands free · ⌃⌥Z or Stop ends it" : "Release to transcribe · tap Z again to lock"))
                    .font(DT.ui(10.5)).foregroundColor(DT.faint)
            }
            Spacer(minLength: 2)
            Text(timeString(state.elapsed)).font(DT.mono(11, .semibold)).foregroundColor(DT.muted).monospacedDigit()
            if locked {
                CtlButton(system: paused ? "play.fill" : "pause.fill", label: paused ? "Resume" : "Pause", tone: DT.fg) { state.onPauseToggle?() }
                CtlButton(system: "stop.fill", label: "Stop", tone: DT.accent) { state.onStop?() }
                CtlButton(system: "xmark", label: "", tone: DT.bad) { state.onCancel?() }
            } else {
                Pill(text: state.lang.label, tone: DT.accent)
            }
        case .transcribing:
            Spinner()
            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribing").font(DT.ui(13, .semibold)).foregroundColor(DT.fg)
                Text("Recording ended").font(DT.ui(10.5)).foregroundColor(DT.faint)
            }
            Spacer(minLength: 2)
            Pill(text: state.lang.label, tone: DT.accent)
        case .done(let text, let pasted):
            Dot(color: DT.good)
            VStack(alignment: .leading, spacing: 2) {
                Text(pasted ? "Pasted" : "Copied to clipboard").font(DT.ui(13, .semibold)).foregroundColor(DT.fg)
                Text(preview(text)).font(DT.ui(10.5)).foregroundColor(DT.faint).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
            }
            Spacer(minLength: 2)
            Pill(text: "\(wordCount(text))W", tone: DT.good)
        case .failed(let msg):
            Dot(color: DT.bad)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg).font(DT.ui(13, .semibold)).foregroundColor(DT.fg).lineLimit(1).frame(maxWidth: 280, alignment: .leading)
                Text("Nothing was saved").font(DT.ui(10.5)).foregroundColor(DT.faint)
            }
        case .warning(let msg):
            Dot(color: DT.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg).font(DT.ui(13, .semibold)).foregroundColor(DT.fg)
                Text("Recording ended").font(DT.ui(10.5)).foregroundColor(DT.faint)
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String { let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60) }
    private func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
    private func preview(_ s: String) -> String { let one = s.replacingOccurrences(of: "\n", with: " "); return one.count > 48 ? String(one.prefix(48)) + "…" : one }
}

/// Bottom-centre bubble on the screen with the pointer. Click-through unless locked.
final class DictationHUD {
    private var panel: NSPanel?
    private let state: DictationState
    private var hideWork: DispatchWorkItem?

    init(state: DictationState) { self.state = state }

    func setInteractive(_ on: Bool) { panel?.ignoresMouseEvents = !on }

    func show() {
        hideWork?.cancel()
        if panel == nil { build() }
        panel?.ignoresMouseEvents = !state.isLocked
        position()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.16; panel?.animator().alphaValue = 1 }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let p = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.22; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func build() {
        let host = NSHostingView(rootView: DictationHUDView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel = p
    }

    private func position() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        p.contentView?.layoutSubtreeIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 300, height: 56)
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: (vf.midX - size.width / 2).rounded(), y: (vf.minY + 64).rounded()))
    }
}
