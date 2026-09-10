import SwiftUI

/// The 400pt menu-bar popover: header + Essentials / Risk / Top Consumers
/// cards on glass, plus the protection footer.
struct DashboardView: View {
    @EnvironmentObject var store: MonitorCenter
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HeaderView()
                CardsContainer {
                    VStack(spacing: 10) {
                        EssentialsCard()
                        RiskCard()
                        TopConsumersCard()
                    }
                }
                FooterView()
            }
            .padding(12)
        }
        .frame(width: 400)
        .frame(maxHeight: 620)
        .onAppear { store.popoverOpened() }
        .onDisappear { store.popoverVisible = false }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI RESOURCE GUARD")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.assessment.level.color)
                        .frame(width: 8, height: 8)
                    Text(store.assessment.level.label)
                        .font(.headline)
                }
            }
            Spacer()
            PressureBadge(pressure: store.pressureLevel)
        }
    }
}

private struct PressureBadge: View {
    let pressure: PressureLevel

    var body: some View {
        Text("Pressure · \(pressure.label)")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(pressure.color.opacity(0.15), in: Capsule())
            .foregroundStyle(pressure.color)
    }
}

// MARK: - Essentials card

private struct EssentialsCard: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if let sample = store.system {
                    Text("\(fmtBytes(sample.usedBytes)) / \(fmtBytes(sample.physicalTotalBytes))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            MemoryBar(sample: store.system)
            if let sample = store.system {
                HStack(spacing: 16) {
                    miniStat("Used", fmtBytes(sample.usedBytes), color: .accentColor)
                    miniStat("Compressed", fmtBytes(sample.compressedBytes), color: .indigo)
                    miniStat("Cached", fmtBytes(sample.cachedBytes), color: .secondary)
                }
                Divider()
                metricRow("Swap", swapText(sample), trailing: fmtRate(sample.swapRateBytesPerMin))
                metricRow("Pressure", store.pressureLevel.label,
                          color: store.pressureLevel.color)
                metricRow("CPU", String(format: "%.0f%%", sample.cpuUsage * 100))
            } else {
                Text("Reading system metrics…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func swapText(_ sample: SystemSample) -> String {
        sample.swapTotalBytes == 0
            ? "0 MB"
            : "\(fmtBytes(sample.swapUsedBytes)) of \(fmtBytes(sample.swapTotalBytes))"
    }
}

private struct MemoryBar: View {
    let sample: SystemSample?

    var body: some View {
        GeometryReader { proxy in
            let total = max(sample.map { Double($0.physicalTotalBytes) } ?? 1, 1)
            let used = sample.map { Double($0.usedBytes) } ?? 0
            let compressed = sample.map { Double($0.compressedBytes) } ?? 0
            let cached = sample.map { Double($0.cachedBytes) } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                HStack(spacing: 1) {
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geo.size.width * (used - compressed) / total)
                            Rectangle().fill(Color.indigo.opacity(0.8))
                                .frame(width: geo.size.width * compressed / total)
                            Rectangle().fill(Color.secondary.opacity(0.5))
                                .frame(width: geo.size.width * cached / total)
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
    }
}

private func miniStat(_ title: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(value).font(.caption).fontWeight(.medium).monospacedDigit()
        Text(title).font(.caption2).foregroundStyle(.tertiary)
    }
}

@ViewBuilder
private func metricRow(_ label: String, _ value: String,
                       color: Color? = nil, trailing: String? = nil) -> some View {
    HStack {
        Text(label).font(.caption).foregroundStyle(.secondary)
        Spacer()
        if let trailing {
            Text(trailing).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        Text(value)
            .font(.caption)
            .fontWeight(.medium)
            .monospacedDigit()
            .foregroundStyle(color ?? .primary)
    }
}

// MARK: - Risk card

private struct RiskCard: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Risk").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(store.assessment.level.label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(store.assessment.level.color)
            }
            if let reason = store.assessment.dominantReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            let rest = store.assessment.reasons.dropFirst().prefix(2)
            if !rest.isEmpty {
                Text(rest.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Divider()
            HStack(alignment: .top) {
                riskStat("System Risk", store.assessment.level.label,
                         color: store.assessment.level.color)
                Divider().frame(height: 28)
                riskStat("Swap Trend",
                         store.system.map { fmtRate($0.swapRateBytesPerMin) } ?? "—",
                         color: trendColor)
                Divider().frame(height: 28)
                riskStat("Memory Pressure", store.pressureLevel.label,
                         color: store.pressureLevel.color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var trendColor: Color {
        guard let rate = store.system?.swapRateBytesPerMin else { return .secondary }
        if rate > 200 * 1_048_576 { return .red }
        if rate > 50 * 1_048_576 { return .orange }
        return .secondary
    }
}

private func riskStat(_ title: String, _ value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption2).foregroundStyle(.tertiary)
        Text(value).font(.caption).fontWeight(.medium).foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Top consumers

private struct TopConsumersCard: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Top Consumers").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text("\(store.groups.count) groups")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if store.groups.isEmpty {
                Text("Scanning processes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(store.groups.prefix(6).enumerated()), id: \.element.id) { index, group in
                    ProcessGroupRow(group: group)
                    if index < min(store.groups.count, 6) - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

// MARK: - Footer

private struct FooterView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        HStack {
            Toggle("Protection", isOn: $settings.settings.autoProtectionEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Spacer()
            Button {
                IncidentWindowController.shared.show()
            } label: {
                Label("Report", systemImage: "chart.xyaxis.line")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}
