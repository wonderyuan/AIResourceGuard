import SwiftUI

/// The 400pt menu-bar popover — the product's primary surface.
///
/// Information architecture (macOS menu-bar utility, not a dashboard):
///   1. 状态：一句话说清楚现在怎么样、为什么
///   2. 四个核心指标：当前内存 / Swap / 内存压力 / Swap 趋势
///   3. 值得关注的应用：风险源优先，其次稳定的大进程；点击展开治理操作
///   4. 自动保护开关 + 二级入口（事件报告 / 设置 / 退出）
///
/// No cards, no charts, no borders: native spacing, typography and a couple
/// of system hairline dividers. Liquid Glass is reserved for the expanded
/// app detail (the key interactive area).
///
/// Sizing is FIXED (Control Center pattern): a MenuBarExtra window that
/// resizes with its content re-anchors under the icon on every height
/// change — with per-second data updates and row expansion this reads as
/// the whole popover "shaking". With a fixed frame the window never
/// resizes; the app list scrolls internally when an expansion overflows.
struct DashboardView: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderView()
            StatusView()
            MetricsGrid()
            Divider()
            NotableAppsSection()
            Spacer(minLength: 0)
            Divider()
            FooterView()
        }
        .padding(16)
        .frame(width: 400, height: 540)
        .onAppear { store.popoverOpened() }
        .onDisappear { store.popoverVisible = false }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("内存守护")
                .font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(store.assessment.level.color)
                    .frame(width: 7, height: 7)
                Text(store.assessment.level.label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(store.assessment.level.color)
                if store.assessment.levelAgeSeconds > 15 {
                    Text("已持续 \(durationText(store.assessment.levelAgeSeconds))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Formats seconds as "42 秒" / "3 分 12 秒" / "1 小时 5 分".
func durationText(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s) 秒" }
    if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
    return "\(s / 3600) 小时 \((s % 3600) / 60) 分"
}

// MARK: - Status sentence + action feedback

private struct StatusView: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(store.assessment.headline)
                .font(.callout)
                .foregroundStyle(store.assessment.level == .normal ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)

            if store.assessment.level >= .warning {
                let rest = store.assessment.reasons.prefix(2)
                if !rest.isEmpty {
                    Text(rest.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let latest = store.actionFeedback.first,
               Date().timeIntervalSince(latest.date) < 600 {
                Label(latest.text, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Four core metrics

private struct MetricsGrid: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if let sample = store.system {
                metricCell(label: "当前内存",
                           value: fmtBytes(sample.usedBytes),
                           sub: "/ \(fmtBytes(sample.physicalTotalBytes))")
                metricCell(label: "Swap",
                           value: sample.swapUsedBytes > 0 ? fmtBytes(sample.swapUsedBytes) : "未使用")
                metricCell(label: "内存压力",
                           value: store.pressureLevel.label,
                           color: store.pressureLevel.color)
                metricCell(label: "Swap 趋势",
                           value: trendText(sample),
                           color: trendColor(sample))
            } else {
                Text("正在读取系统指标…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func trendText(_ sample: SystemSample) -> String {
        let mbMin = sample.swapRateBytesPerMin / 1_048_576
        if mbMin >= 5 { return "↑ \(String(format: "%.0f", mbMin)) MB/分" }
        if mbMin <= -5 { return "↓ \(String(format: "%.0f", -mbMin)) MB/分" }
        return "平稳"
    }

    private func trendColor(_ sample: SystemSample) -> Color {
        let mbMin = sample.swapRateBytesPerMin / 1_048_576
        if mbMin >= 200 { return .red }
        if mbMin >= 50 { return .orange }
        if mbMin <= -5 { return .green }
        return .secondary
    }

    private func metricCell(label: String, value: String,
                            sub: String? = nil, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(color ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let sub {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notable apps

private struct NotableAppsSection: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("值得关注的应用")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if store.notableApps.isEmpty {
                Text(store.groups.isEmpty ? "正在扫描…" : "当前没有需要关注的应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Sized by the fixed popover frame — expansion scrolls
                // inside instead of resizing (and re-anchoring) the window.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.notableApps) { group in
                            ProcessGroupRow(group: group)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Footer

private struct FooterView: View {
    @EnvironmentObject var store: MonitorCenter
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        HStack(spacing: 10) {
            Toggle("自动保护", isOn: $settings.settings.autoProtectionEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            Spacer()
            Button {
                IncidentWindowController.shared.show()
            } label: {
                Label("事件报告", systemImage: "chart.xyaxis.line")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("查看风险时间线与历史记录")
            SettingsLink {
                Label("设置", systemImage: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}
