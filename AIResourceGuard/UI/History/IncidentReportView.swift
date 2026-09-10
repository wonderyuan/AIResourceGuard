import SwiftUI

/// Post-mortem report: what dragged the machine down, and when.
/// Rebuilt from history snapshots — works even after a hard lockup.
struct IncidentReportView: View {
    @EnvironmentObject var store: MonitorCenter
    @State private var snapshots: [HistorySnapshot] = []
    @State private var rangeHours = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Incident Report")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Picker("Range", selection: $rangeHours) {
                    Text("1h").tag(1)
                    Text("6h").tag(6)
                    Text("24h").tag(24)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .onChange(of: rangeHours) { _ in reload() }
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)

            Divider()

            if snapshots.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("Not enough history yet")
                        .font(.callout)
                    Text("Snapshots are recorded every 30–120s. Come back after a few minutes — or after the next incident.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryRow
                        RiskTimeline(snapshots: snapshots)
                        offendersSection
                        if let fastest = fastestGrowingLine {
                            Label(fastest, systemImage: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onAppear { reload() }
    }

    // MARK: - Data

    private func reload() {
        HistoryStore.shared.fetchSnapshots(hours: TimeInterval(rangeHours)) { snaps in
            snapshots = snaps
        }
    }

    private var peakRisk: RiskLevel {
        snapshots.map(\.riskLevel).max() ?? .normal
    }

    private var peakSwap: HistorySnapshot? {
        snapshots.max { $0.swapUsedBytes < $1.swapUsedBytes }
    }

    private var fastestGrowingLine: String? {
        let names = snapshots.compactMap(\.fastestGrowing)
        guard let last = names.last else { return nil }
        return "Last flagged fastest-growing group: \(last)"
    }

    // MARK: - Sections

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 12) {
            statBlock("Peak Risk", peakRisk.label, color: peakRisk.color)
            Divider().frame(height: 34)
            statBlock("Peak Swap",
                      peakSwap.map { fmtBytes($0.swapUsedBytes) } ?? "—",
                      caption: peakSwap.map { $0.timestamp.formatted(date: .omitted, time: .shortened) },
                      color: .orange)
            Divider().frame(height: 34)
            statBlock("Memory at End",
                      fmtBytes(snapshots.last?.memUsedBytes ?? 0),
                      caption: snapshots.last.map {
                          "\($0.memTotalBytes > 0 ? Int(Double($0.memUsedBytes) / Double($0.memTotalBytes) * 100) : 0)% of physical"
                      },
                      color: .accentColor)
            Divider().frame(height: 34)
            statBlock("Snapshots", "\(snapshots.count)", color: .secondary)
            Spacer()
        }
    }

    private func statBlock(_ title: String, _ value: String,
                           caption: String? = nil, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.title3).fontWeight(.semibold).foregroundStyle(color)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var offenders: [GroupPeak] {
        var peaks: [String: GroupPeak] = [:]
        for snapshot in snapshots {
            for entry in snapshot.top {
                if peaks[entry.name] == nil || peaks[entry.name]!.peakRSSBytes < entry.rssBytes {
                    peaks[entry.name] = GroupPeak(
                        name: entry.name,
                        peakRSSBytes: entry.rssBytes,
                        at: snapshot.timestamp,
                        trendBytesPerMin: entry.trendBytesPerMin)
                }
            }
        }
        return peaks.values.sorted { $0.peakRSSBytes > $1.peakRSSBytes }.prefix(6).map { $0 }
    }

    private var offendersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heaviest processes in this window")
                .font(.subheadline)
                .fontWeight(.semibold)
            ForEach(offenders) { peak in
                HStack(spacing: 8) {
                    Text(peak.name)
                        .font(.callout)
                        .lineLimit(1)
                    if abs(peak.trendBytesPerMin) > 100 * 1_048_576 {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(peak.at.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(fmtBytes(peak.peakRSSBytes))
                        .font(.callout)
                        .monospacedDigit()
                }
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

struct GroupPeak: Identifiable {
    let name: String
    let peakRSSBytes: UInt64
    let at: Date
    let trendBytesPerMin: Double
    var id: String { name }
}

// MARK: - Timeline chart

/// Memory / swap lines over time with a risk-level color band on top.
/// Pure SwiftUI Canvas, no third-party charting.
struct RiskTimeline: View {
    let snapshots: [HistorySnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                draw(context: context, size: size)
            }
            .frame(height: 140)
            HStack(spacing: 12) {
                legendDot(.accentColor, "Memory used")
                legendDot(.orange, "Swap used")
                legendDot(peakRiskColor, "Risk band")
                Spacer()
                Text(timeLabel(first))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Text("–")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(timeLabel(last))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var first: Date? { snapshots.first?.timestamp }
    private var last: Date? { snapshots.last?.timestamp }

    private var peakRiskColor: Color {
        snapshots.map(\.riskLevel).max()?.color ?? .green
    }

    private func timeLabel(_ date: Date?) -> String {
        date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—"
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        guard snapshots.count >= 2,
              let firstTS = first?.timeIntervalSince1970,
              let lastTS = last?.timeIntervalSince1970,
              lastTS > firstTS else { return }

        let span = lastTS - firstTS
        func x(_ ts: TimeInterval) -> CGFloat {
            CGFloat((ts - firstTS) / span) * size.width
        }
        func ts(_ s: HistorySnapshot) -> TimeInterval {
            s.timestamp.timeIntervalSince1970
        }

        let bandHeight: CGFloat = 7
        let chartTop: CGFloat = bandHeight + 5
        let chartHeight = size.height - chartTop

        // Risk band across the top.
        for (index, snapshot) in snapshots.enumerated() {
            let x0 = x(ts(snapshot))
            let x1 = index + 1 < snapshots.count
                ? x(ts(snapshots[index + 1])) : size.width
            let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: bandHeight)
            context.fill(Path(rect), with: .color(snapshot.riskLevel.color.opacity(0.85)))
        }

        let memTotal = Double(snapshots.last?.memTotalBytes ?? 0) > 0
            ? Double(snapshots.last!.memTotalBytes) : 16 * 1_073_741_824
        let swapMax = max(snapshots.map { Double($0.swapUsedBytes) }.max() ?? 0,
                          512 * 1_048_576)

        func y(_ value: Double, scale: Double) -> CGFloat {
            chartTop + chartHeight * CGFloat(1 - min(max(value / scale, 0), 1))
        }

        // Swap area + line.
        var swapArea = Path()
        swapArea.move(to: CGPoint(x: 0, y: size.height))
        for snapshot in snapshots {
            swapArea.addLine(to: CGPoint(x: x(ts(snapshot)), y: y(Double(snapshot.swapUsedBytes), scale: swapMax)))
        }
        swapArea.addLine(to: CGPoint(x: size.width, y: size.height))
        swapArea.closeSubpath()
        context.fill(swapArea, with: .color(.orange.opacity(0.18)))

        var swapLine = Path()
        for (index, snapshot) in snapshots.enumerated() {
            let point = CGPoint(x: x(ts(snapshot)), y: y(Double(snapshot.swapUsedBytes), scale: swapMax))
            if index == 0 { swapLine.move(to: point) } else { swapLine.addLine(to: point) }
        }
        context.stroke(swapLine, with: .color(.orange), lineWidth: 1.5)

        // Memory line.
        var memLine = Path()
        for (index, snapshot) in snapshots.enumerated() {
            let point = CGPoint(x: x(ts(snapshot)), y: y(Double(snapshot.memUsedBytes), scale: memTotal))
            if index == 0 { memLine.move(to: point) } else { memLine.addLine(to: point) }
        }
        context.stroke(memLine, with: .color(.accentColor), lineWidth: 1.5)

        // Peak swap marker.
        if let peak = peakSwapSnapshot {
            let center = CGPoint(x: x(ts(peak)), y: y(Double(peak.swapUsedBytes), scale: swapMax))
            let dot = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dot), with: .color(.orange))
        }
    }

    private var peakSwapSnapshot: HistorySnapshot? {
        snapshots.max { $0.swapUsedBytes < $1.swapUsedBytes }
    }
}
