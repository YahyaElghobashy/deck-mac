import Combine
import Murmur
import SwiftUI

/// Dictation metrics (FND-10): p50 and p95 per path, from the local database only.
struct MetricsView: View {
    @StateObject private var model = MetricsModel()

    /// Targets from the PRD, by path. Paths without one are shown for information.
    private static let targets: [String: Int] = ["release_to_text.whisper": 1000]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation metrics").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Theme.text)
                    Text("Recorded on this Mac only, never sent anywhere. The last 200 events per path.")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("Clear") { model.clear() }.buttonStyle(SecondaryButtonStyle())
            }
            if model.rows.isEmpty {
                Text("Nothing yet. Dictate something and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    header
                    ForEach(model.rows, id: \.path) { row($0) }
                }
                .card(radius: 12)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 360, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Path").frame(maxWidth: .infinity, alignment: .leading)
            Text("Count").frame(width: 60, alignment: .trailing)
            Text("p50").frame(width: 80, alignment: .trailing)
            Text("p95").frame(width: 80, alignment: .trailing)
            Text("Target").frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.text3)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func row(_ m: Store.MetricSummary) -> some View {
        let target = Self.targets[m.path]
        let over = target.flatMap { t in m.p50.map { $0 > t } } ?? false
        return HStack {
            Text(m.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(m.count)").frame(width: 60, alignment: .trailing)
            Text(m.p50.map { "\($0) ms" } ?? "–").foregroundStyle(over ? Theme.gold : Theme.text).frame(width: 80, alignment: .trailing)
            Text(m.p95.map { "\($0) ms" } ?? "–").frame(width: 80, alignment: .trailing)
            Text(target.map { "≤ \($0) ms" } ?? "").foregroundStyle(Theme.text3).frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.text2)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.stroke.frame(height: 1), alignment: .top)
    }
}

/// Re-reads the summaries every two seconds while the window is open. (An ObservableObject rather
/// than @State: the State macro has no plugin outside Xcode.)
@MainActor
final class MetricsModel: ObservableObject {
    @Published var rows: [Store.MetricSummary] = []
    private var timer: AnyCancellable?

    init() {
        refresh()
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }
    }

    func refresh() { rows = DictationController.shared.metricSummaries() }
    func clear() { DictationController.shared.clearMetrics(); refresh() }

    static let openNotification = Notification.Name("com.yahya.deck.openMetrics")
}
