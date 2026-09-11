import SwiftUI
import os

private let rowLog = Logger(subsystem: "local.dev.AIResourceGuard", category: "row")

/// One app/task row. Used in both "谁在占用内存" and "已暂停的任务" sections.
/// Collapsed: name, memory, trend, CPU, tags. Expanded: process tree +
/// 暂停/恢复/终止.
///
/// CRITICAL INTERACTION NOTE:
/// SwiftUI Button does NOT receive mouse events inside MenuBarExtra
/// popovers on macOS 26. All interactive elements use .onTapGesture +
/// .contentShape instead.
struct ProcessGroupRow: View {
    let group: ProcessGroupInfo

    @EnvironmentObject var store: MonitorCenter
    @State private var expanded = false
    @State private var terminateArmed = false
    @State private var tapFlash = false
    /// Three-state optimistic pause: .paused forces "paused" look,
    /// .active forces "running" look, .none defers to scan data.
    @State private var optimisticState: OptimisticState = .none

    enum OptimisticState {
        case none, paused, active
    }

    private var isProtected: Bool {
        store.settingsStore.isProtectedGroup(group.key)
    }

    /// Visual pause state: optimistic override or scan data.
    private var isPaused: Bool {
        switch optimisticState {
        case .paused: return true
        case .active: return false
        case .none: return group.anyStopped
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            rowHeader
            if expanded {
                detail
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Row header (gray when paused, but buttons stay vivid)

    private var rowHeader: some View {
        HStack(spacing: 8) {
            GroupIconView(group: group)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.displayName)
                        .font(.callout)
                        .lineLimit(1)
                    if group.isRiskSource && !isPaused {
                        Text("增长异常").tagStyle(.orange)
                    }
                    if group.isStaleWorkload && !isPaused {
                        Text("遗留任务").tagStyle(.teal)
                    }
                    if isPaused {
                        Text("已暂停")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if isProtected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(trendText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(trendColor)
            Text(fmtBytes(group.displayMemoryBytes))
                .font(.callout)
                .monospacedDigit()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            terminateArmed = false
        }
        // Dim only the collapsed header; the expanded detail keeps full
        // color so buttons don't look disabled.
        .opacity(isPaused && !expanded ? 0.55 : 1.0)
        .saturation(isPaused && !expanded ? 0.3 : 1.0)
    }

    private var cpuText: String {
        let pct = group.cpuFraction * 100
        return pct >= 100 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }

    private var subtitle: String {
        var parts = ["\(group.processes.count) 个进程 · CPU \(cpuText)"]
        if group.isStaleWorkload {
            parts.append("闲置 \(Int(group.ageSeconds / 60)) 分钟")
        }
        return parts.joined(separator: " · ")
    }

    private var trendText: String {
        if isPaused { return "已暂停" }
        let mbMin = group.footprintTrendBytesPerMin / 1_048_576
        if mbMin >= 1000 { return String(format: "↑ %.1f GB/分", mbMin / 1000) }
        if mbMin > 50 { return String(format: "↑ %.0f MB/分", mbMin) }
        if mbMin < -50 { return String(format: "↓ %.0f MB/分", -mbMin) }
        return "稳定"
    }

    private var trendColor: Color {
        if isPaused { return .orange }
        switch group.trendDirection {
        case .up: return .red
        case .down: return .green
        case .flat: return .secondary
        }
    }

    // MARK: - Expanded detail (always full color, buttons vivid)

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            let parentPids = Set(group.processes.map(\.ppid))
            ForEach(Array(group.processes.prefix(8).enumerated()), id: \.element.pid) { _, proc in
                HStack(spacing: 6) {
                    Text("\(proc.pid)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    Text(proc.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, parentPids.contains(proc.ppid) ? 10 : 0)
                    if proc.isMCP {
                        Text("MCP").tagStyle(.blue)
                    }
                    Spacer()
                    if proc.isStopped {
                        Image(systemName: "pause.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(fmtBytes(proc.rssBytes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", proc.cpuFraction * 100))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
            if group.processes.count > 8 {
                Text("还有 \(group.processes.count - 8) 个进程…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Action bar — onTapGesture, NOT Button.
            HStack(spacing: 12) {
                if terminateArmed {
                    tapAction(
                        title: "确认终止 \(group.displayName)",
                        icon: "exclamationmark.triangle.fill",
                        bg: .red.opacity(0.15),
                        fg: .red
                    ) {
                        terminateArmed = false
                        store.protection.terminate(group)
                        store.popoverOpened()
                    }
                    tapAction(title: "取消", icon: "xmark",
                              bg: Color(nsColor: .quaternaryLabelColor), fg: .secondary) {
                        terminateArmed = false
                    }
                } else {
                    tapAction(
                        title: isPaused ? "恢复任务" : "暂停任务",
                        icon: isPaused ? "play.fill" : "pause.fill",
                        bg: isPaused ? .green.opacity(0.15) : .accentColor.opacity(0.15),
                        fg: isPaused ? .green : .accentColor
                    ) {
                        if isPaused {
                            // Optimistic: show running immediately.
                            optimisticState = .active
                            store.protection.resume(group)
                        } else {
                            // Optimistic: show paused immediately, collapse.
                            optimisticState = .paused
                            withAnimation(Design.Motion.fast) { expanded = false }
                            store.protection.pause(group)
                        }
                        store.popoverOpened()
                    }

                    Spacer()

                    tapAction(title: "终止", icon: "xmark",
                              bg: .red.opacity(0.1), fg: .red) {
                        terminateArmed = true
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35),
                    in: .rect(cornerRadius: Design.Radius.panel))
    }

    /// Custom tappable label — bypasses Button entirely.
    private func tapAction(title: String, icon: String,
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

// MARK: - Icon

struct GroupIconView: View {
    let group: ProcessGroupInfo
    @State private var nsImage: NSImage?

    var body: some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage).resizable().scaledToFit()
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadIcon() }
    }

    private var symbolName: String {
        switch group.key {
        case "node", "bun", "deno": return "terminal"
        case "xcode": return "hammer"
        case "sim": return "iphone"
        case "codex": return "brain"
        default:
            if group.key.hasPrefix("exe:") { return "terminal" }
            return "app.dashed"
        }
    }

    private func loadIcon() {
        guard group.isApp, let path = group.iconPath else { return }
        nsImage = IconCache.shared.icon(for: path)
    }
}
