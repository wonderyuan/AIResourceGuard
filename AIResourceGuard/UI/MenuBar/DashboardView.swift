import SwiftUI

/// The 400pt menu-bar popover — the product's primary surface.
///
/// ONE visual core: 系统余量 (how much room is left). Everything else is
/// typography. The panel has three height tiers tied to the risk level:
///
/// - Compact (正常): status + headroom + footer;
/// - Attention (注意): + what's happening + who's using memory;
/// - Intervention (压力较高/即将失控): full explanation + actions.
///
/// Window size is FIXED per tier so it never re-anchors while open; only a
/// genuine risk-level change can switch tiers. Liquid Glass appears only on
/// the expanded app panel (the key interactive surface).
struct DashboardView: View {
    @EnvironmentObject var store: MonitorCenter

    private enum Tier {
        case compact, attention, intervention

        var height: CGFloat {
            switch self {
            case .compact: return 252
            case .attention: return 470
            case .intervention: return 560
            }
        }
    }

    private var tier: Tier {
        // Paused tasks force at least the Attention tier so their resume
        // buttons stay visible — a paused task the user can't find to resume
        // is a frozen process left behind forever.
        let hasPausedTasks = store.notableApps.contains { $0.anyStopped }
            || store.groups.contains { $0.anyStopped }
        switch store.assessment.level {
        case .normal:
            return hasPausedTasks ? .attention : .compact
        case .warning: return .attention
        case .danger, .critical: return .intervention
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HeaderView()

            HeadroomHero()

            if tier != .compact {
                StatusView()
                Divider()
                NotableAppsSection()
                Spacer(minLength: 0)
                Divider()
            } else {
                Spacer(minLength: 0)
            }

            FooterView()
        }
        .padding(Design.Space.l)
        .frame(width: 400, height: tier.height)
        .onAppear { store.popoverOpened() }
        .onDisappear { store.popoverVisible = false }
        .animation(Design.Motion.standard, value: store.assessment.level)
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
                if store.assessment.level != .normal, store.assessment.levelAgeSeconds > 15 {
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

// MARK: - Headroom hero (the single visual core)

private struct HeadroomHero: View {
    @EnvironmentObject var store: MonitorCenter

    /// Room before the machine has to dig deeper into swap:
    /// physical − (wired + active + compressed).
    private var availableBytes: UInt64 {
        guard let sample = store.system else { return 0 }
        return sample.usedBytes < sample.physicalTotalBytes
            ? sample.physicalTotalBytes - sample.usedBytes : 0
    }

    private var availableGB: Double {
        Double(availableBytes) / 1_073_741_824
    }

    private var availablePercent: Double {
        guard let total = store.system?.physicalTotalBytes, total > 0 else { return 0 }
        return Double(availableBytes) / Double(total)
    }

    private var headroomColor: Color {
        switch availablePercent {
        case ..<0.05: return .red
        case ..<0.12: return .orange
        case ..<0.25: return .yellow
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(availableGB >= 10
                     ? String(format: "%.0f", availableGB)
                     : String(format: "%.1f", availableGB))
                    .font(Design.Typo.heroValue)
                    .monospacedDigit()
                    .foregroundStyle(headroomColor)
                Text("GB 系统余量")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(availablePercent * 100))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.5))
                    Capsule()
                        .fill(headroomColor.opacity(0.85))
                        .frame(width: max(proxy.size.width * availablePercent, 3))
                }
            }
            .frame(height: 6)

            if let sample = store.system {
                swapLine(sample)
            }
        }
    }

    @ViewBuilder
    private func swapLine(_ sample: SystemSample) -> some View {
        let swapMB = Double(sample.swapUsedBytes) / 1_048_576
        let rateMB = sample.swapRateBytesPerMin / 1_048_576
        if swapMB > 512 {
            HStack(spacing: 5) {
                Text("Swap 已用 \(fmtBytes(sample.swapUsedBytes))")
                if rateMB >= 5 {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(String(format: "%.0f", rateMB)) MB/分")
                } else if rateMB <= -5 {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(String(format: "%.0f", -rateMB)) MB/分")
                } else {
                    Text("· 平稳")
                }
                if store.pressureLevel != .normal {
                    Text("· 内存压力\(store.pressureLevel.label)")
                        .foregroundStyle(store.pressureLevel.color)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else if store.pressureLevel != .normal {
            Text("内存压力\(store.pressureLevel.label)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Status

private struct StatusView: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        let level = store.assessment.level
        VStack(alignment: .leading, spacing: 5) {
            Text(store.assessment.headline)
                .font(level == .critical
                      ? .system(.body, design: .rounded).weight(.semibold)
                      : .callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Image(systemName: store.notableContext.source.symbol)
                    .font(.caption2)
                Text(sourceText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            // "去向不明" only when we genuinely couldn't identify a cause.
            // Never show it alongside a specific cause — that's contradictory.
            if store.notableContext.source == .incompleteAttribution && level >= .danger {
                Label("系统压力严重，部分内存去向不明", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let latest = store.actionFeedback.first,
               Date().timeIntervalSince(latest.date) < 5 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                    Text(latest.text)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.12), in: .rect(cornerRadius: 10))
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }

    private var sourceText: String {
        let source = store.notableContext.source
        guard source != .none, source != .incompleteAttribution else { return "" }
        if case .singleRunaway(let name) = source {
            return "原因：\(name) 增长失控"
        }
        return "原因：\(source.label)"
    }
}

// MARK: - Notable apps

private struct NotableAppsSection: View {
    @EnvironmentObject var store: MonitorCenter

    private var activeGroups: [ProcessGroupInfo] {
        let pausedKeys = Set(store.pausedTasks.map(\.groupKey))
        return store.notableApps.filter { group in
            !group.anyStopped && !pausedKeys.contains(group.key)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Active consumers ─────────────────────────────────────
            if !activeGroups.isEmpty {
                Text("谁在占用内存")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if store.notableContext.fallbackOnly {
                    Text("没有单一明显来源，先看占用最高的应用")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                VStack(spacing: 0) {
                    ForEach(activeGroups.prefix(3)) { group in
                        ProcessGroupRow(group: group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── Paused tasks (dedicated section, always visible) ─────
            if !store.pausedTasks.isEmpty {
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("已暂停的任务")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("（点击恢复）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                VStack(spacing: 0) {
                    ForEach(store.pausedTasks, id: \.groupKey) { task in
                        PausedTaskRow(task: task)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if activeGroups.isEmpty && store.pausedTasks.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    private var emptyMessage: String {
        if store.groups.isEmpty { return "正在了解正在运行的应用…" }
        if store.assessment.level >= .danger {
            return store.notableContext.attributionIncomplete
                ? "系统压力严重，部分内存去向不明"
                : "没有单一明显来源"
        }
        return "没有需要处理的应用"
    }
}

// MARK: - Paused task row (driven by the ledger, not scan data)

private struct PausedTaskRow: View {
    let task: PausedTask
    @EnvironmentObject var store: MonitorCenter
    @State private var tapFlash = false
    @State private var confirmTerminate = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayName)
                    .font(.callout)
                Text("\(task.identities.count) 个进程 · \(fmtBytes(task.footprintBytes))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()

            if confirmTerminate {
                // SAME pattern as ProcessGroupRow (verified working)
                actionButton("确认终止", icon: "exclamationmark.triangle.fill",
                             bg: .red.opacity(0.15), fg: .red) {
                    confirmTerminate = false
                    store.protection.terminatePausedTask(task)
                }
                actionButton("取消", icon: "xmark",
                             bg: Color(nsColor: .quaternaryLabelColor), fg: .secondary) {
                    confirmTerminate = false
                }
            } else {
                actionButton("恢复", icon: "play.fill",
                             bg: .green.opacity(0.15), fg: .green) {
                    store.protection.resumePausedTask(task)
                }
                actionButton("终止", icon: "xmark",
                             bg: .red.opacity(0.1), fg: .red) {
                    confirmTerminate = true
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    /// EXACT copy of ProcessGroupRow's tapAction (verified working).
    private func actionButton(_ title: String, icon: String,
                              bg: Color, fg: Color,
                              action: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tapFlash ? fg.opacity(0.3) : bg,
                    in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(fg)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.1)) { tapFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.2)) { tapFlash = false }
            }
            action()
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
            .help("查看每次压力事件的完整过程")
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
