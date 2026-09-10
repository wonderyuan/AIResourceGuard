import SwiftUI

/// Post-mortem report, organized around pressure episodes: pick an episode,
/// read its narrative, timeline, suspects and the protection actions taken.
/// Episodes are derived from persisted history, so the story survives even
/// a hard lockup.
struct IncidentReportView: View {
    @EnvironmentObject var store: MonitorCenter
    @State private var episodes: [PressureEpisode] = []
    @State private var selectedID: PressureEpisode.ID?
    @State private var allSnapshots: [HistorySnapshot] = []
    @State private var events: [HistoryEvent] = []
    @State private var windowSnapshots: [HistorySnapshot] = []
    @State private var summary: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("事件报告")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)

            Divider()

            if episodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("最近 24 小时没有压力事件")
                        .font(.callout)
                    Text("快照每 30–120 秒记录一次；下一次事件之后，这里会有完整的时间线与归因。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    episodeChips
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    Divider()

                    if let episode = selected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                summarySection(episode)
                                statsRow(episode)
                                RiskTimeline(snapshots: windowSnapshots)
                                suspectsSection(episode)
                                actionsSection(episode)
                            }
                            .padding(12)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { reload() }
    }

    // MARK: - Data

    private var selected: PressureEpisode? {
        episodes.first { $0.id == selectedID } ?? episodes.first
    }

    private func reload() {
        HistoryStore.shared.fetchSnapshots(hours: 24) { snapshots in
            self.allSnapshots = snapshots
            HistoryStore.shared.recentEvents(limit: 500) { events in
                self.events = events
                self.episodes = EpisodeBuilder.build(snapshots: snapshots, events: events)
                if selectedID == nil { selectedID = episodes.first?.id }
                applySelection()
            }
        }
    }

    /// Snapshots + narrative for one episode window (with a small lead-in so
    /// growth has a "before" to compare against).
    private func applySelection() {
        guard let episode = selected else {
            windowSnapshots = []
            summary = []
            return
        }
        let start = episode.startedAt.addingTimeInterval(-20 * 60)
        let end = (episode.endedAt ?? Date()).addingTimeInterval(5 * 60)
        windowSnapshots = allSnapshots.filter {
            $0.timestamp >= start && $0.timestamp <= end
        }
        let windowEvents = events.filter {
            $0.timestamp >= start && $0.timestamp <= end
        }
        summary = IncidentSummarizer.summarize(snapshots: windowSnapshots, events: windowEvents)
    }

    // MARK: - Episode chips

    private var episodeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(episodes) { episode in
                    Button {
                        selectedID = episode.id
                        applySelection()
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(episode.peakRisk.color)
                                .frame(width: 6, height: 6)
                            Text(episode.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .monospacedDigit()
                            Text(episode.peakRisk.label)
                                .font(.caption)
                                .foregroundStyle(episode.peakRisk.color)
                            if episode.endedAt == nil {
                                Text("进行中")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            episode.id == selected?.id
                                ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                : AnyShapeStyle(Color(nsColor: .quaternaryLabelColor)),
                            in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sections

    private func summarySection(_ episode: PressureEpisode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("事故摘要", systemImage: "text.alignleft")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(summary.indices, id: \.self) { index in
                Text(summary[index])
                    .font(.callout)
                    .foregroundStyle(index == summary.count - 1 ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    private func statsRow(_ episode: PressureEpisode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statBlock("峰值风险", episode.peakRisk.label, color: episode.peakRisk.color)
            Divider().frame(height: 34)
            statBlock("峰值 Swap", fmtBytes(episode.peakSwapBytes),
                      caption: episode.peakSwapAt.formatted(date: .omitted, time: .shortened),
                      color: .orange)
            Divider().frame(height: 34)
            statBlock("峰值增速",
                      String(format: "%.0f MB/分钟", episode.maxSwapRateBytesPerMin / 1_048_576),
                      color: .secondary)
            Divider().frame(height: 34)
            statBlock("持续", durationText(episode), color: .secondary)
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

    private func durationText(_ episode: PressureEpisode) -> String {
        let minutes = Int(episode.durationSeconds / 60)
        return minutes > 0 ? "\(minutes) 分钟" : "\(Int(episode.durationSeconds)) 秒"
    }

    private func suspectsSection(_ episode: PressureEpisode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("异常增长的应用")
                .font(.subheadline)
                .fontWeight(.semibold)
            if episode.suspects.isEmpty {
                Text("期间没有发现显著增长的应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(episode.suspects) { suspect in
                HStack(spacing: 8) {
                    Text(suspect.name).font(.callout).lineLimit(1)
                    Image(systemName: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Spacer()
                    Text("\(fmtBytes(suspect.startBytes)) → \(fmtBytes(suspect.peakBytes))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("+\(fmtBytes(suspect.growthBytes))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }

    private func actionsSection(_ episode: PressureEpisode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("保护动作")
                .font(.subheadline)
                .fontWeight(.semibold)
            if episode.actions.isEmpty {
                Text("期间未执行自动保护动作（未开启或未达到触发条件）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(episode.actions) { action in
                    HistoryEventRow(event: action)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }
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
                legendDot(.accentColor, "内存")
                legendDot(.orange, "Swap")
                legendDot(peakRiskColor, "风险")
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
        .glassSurface()
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
