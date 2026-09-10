import SwiftUI

/// Event history browser (Settings ▸ History). Answers the post-mortem
/// question: "which process dragged the machine down, and when".
struct HistoryView: View {
    @State private var events: [HistoryEvent] = []
    @State private var snapshots: [HistorySnapshot] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(events.count) 条事件（最近 24 小时，最多 1000 条）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button {
                    HistoryStore.shared.clear()
                    events = []
                    snapshots = []
                } label: {
                    Label("清空", systemImage: "trash")
                }
            }
            .padding(8)

            Divider()

            if events.isEmpty && snapshots.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("暂无事件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if snapshots.count >= 2 {
                        Section {
                            RiskTimeline(snapshots: snapshots)
                                .listRowSeparator(.hidden)
                        } header: {
                            Text("最近 6 小时 — 内存 / Swap / 风险")
                        }
                    }
                    Section("事件列表") {
                        ForEach(events) { event in
                            HistoryEventRow(event: event)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        HistoryStore.shared.recentEvents(limit: 500) { events in
            self.events = events
        }
        HistoryStore.shared.fetchSnapshots(hours: 6) { snapshots in
            self.snapshots = snapshots
        }
    }
}

private struct HistoryEventRow: View {
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
