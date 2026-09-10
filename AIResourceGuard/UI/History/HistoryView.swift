import SwiftUI

/// Settings ▸ 历史记录 — organized around pressure episodes, with the raw
/// event stream below for completeness.
struct HistoryPage: View {
    @State private var episodes: [PressureEpisode] = []
    @State private var events: [HistoryEvent] = []
    @State private var expandedEpisode: PressureEpisode.ID?

    var body: some View {
        List {
            Section("压力事件") {
                if episodes.isEmpty {
                    Text("最近 24 小时没有压力事件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode,
                                   expanded: expandedEpisode == episode.id) {
                            expandedEpisode = expandedEpisode == episode.id ? nil : episode.id
                        }
                    }
                }
            }

            Section("全部事件") {
                if events.isEmpty {
                    Text("暂无事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        HistoryEventRow(event: event)
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        HistoryStore.shared.fetchSnapshots(hours: 24) { snapshots in
            HistoryStore.shared.recentEvents(limit: 500) { events in
                self.events = events
                self.episodes = EpisodeBuilder.build(snapshots: snapshots, events: events)
            }
        }
    }
}

/// One pressure episode, summarized: when, how bad, who, what was done.
private struct EpisodeRow: View {
    let episode: PressureEpisode
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Circle().fill(episode.peakRisk.color).frame(width: 7, height: 7)
                    Text(timeRange).font(.callout).monospacedDigit()
                    Text("峰值 \(episode.peakRisk.label)")
                        .font(.caption)
                        .foregroundStyle(episode.peakRisk.color)
                    Text("Swap \(fmtBytes(episode.startSwapBytes)) → \(fmtBytes(episode.peakSwapBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let suspect = episode.primarySuspect {
                        Text(suspect.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("持续时间", durationText)
                    detailRow("峰值增速", String(format: "%.0f MB/分钟", episode.maxSwapRateBytesPerMin / 1_048_576))
                    if let suspect = episode.primarySuspect {
                        detailRow("主要嫌疑", "\(suspect.name)（+\(fmtBytes(suspect.growthBytes))）")
                    }
                    detailRow("恢复时间", episode.endedAt.map {
                        $0.formatted(date: .omitted, time: .shortened)
                    } ?? "进行中")
                    if !episode.actions.isEmpty {
                        ForEach(episode.actions.prefix(5)) { action in
                            Label(action.summary, systemImage: "hand.raised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("期间未执行保护动作")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 15)
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let start = episode.startedAt.formatted(date: .omitted, time: .shortened)
        let end = episode.endedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "…"
        return "\(start) – \(end)"
    }

    private var durationText: String {
        let minutes = Int(episode.durationSeconds / 60)
        return minutes > 0 ? "约 \(minutes) 分钟" : "\(Int(episode.durationSeconds)) 秒"
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct HistoryEventRow: View {
    let event: HistoryEvent
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.summary)
                        .font(.caption)
                        .lineLimit(expanded ? nil : 2)
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if event.detail != nil {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { expanded.toggle() } }

            if expanded, let detail = event.detail {
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch event.kind {
        case "riskChange": return "exclamationmark.triangle"
        case "pressureChange": return "gauge.with.needle.33percent"
        case "snapshot": return "camera.metering.matrix"
        case "action": return "hand.raised"
        case "launch": return "power"
        default: return "circle"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case "riskChange": return .orange
        case "pressureChange": return .yellow
        case "snapshot": return .secondary
        case "action": return .red
        case "launch": return .green
        default: return .secondary
        }
    }
}
