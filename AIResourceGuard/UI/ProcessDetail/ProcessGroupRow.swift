import SwiftUI

/// One row in "谁在占用内存". Collapsed: name, aggregated memory, growth
/// trend, CPU, risk-source tag. Expanded: process tree + 暂停/恢复/终止.
///
/// IMPORTANT: no confirmationDialog / alert here — in a MenuBarExtra window
/// they steal focus and dismiss the entire popover. Destructive actions use
/// inline two-click confirm instead.
struct ProcessGroupRow: View {
    let group: ProcessGroupInfo

    @EnvironmentObject var store: MonitorCenter
    @State private var expanded = false
    /// Inline two-click confirm for destructive actions (never a dialog —
    /// dialogs close the whole popover in MenuBarExtra).
    @State private var terminateArmed = false

    private var isProtected: Bool {
        store.settingsStore.isProtectedGroup(group.key)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                terminateArmed = false
            } label: {
                HStack(spacing: 8) {
                    GroupIconView(group: group)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.displayName)
                                .font(.callout)
                                .lineLimit(1)
                            if group.isRiskSource {
                                Text("增长异常").tagStyle(.orange)
                            }
                            if group.isStaleWorkload {
                                Text("遗留任务").tagStyle(.teal)
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
            }
            .buttonStyle(.plain)

            if expanded {
                detail
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
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
        let mbMin = group.footprintTrendBytesPerMin / 1_048_576
        if mbMin >= 1000 { return String(format: "↑ %.1f GB/分", mbMin / 1000) }
        if mbMin > 50 { return String(format: "↑ %.0f MB/分", mbMin) }
        if mbMin < -50 { return String(format: "↓ %.0f MB/分", -mbMin) }
        return "稳定"
    }

    private var trendColor: Color {
        switch group.trendDirection {
        case .up: return .red
        case .down: return .green
        case .flat: return .secondary
        }
    }

    // MARK: - Expanded detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if group.anyStopped {
                Label("已暂停", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

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

            // Inline two-click confirm: first click arms the button, second
            // click executes. NEVER use confirmationDialog here — it steals
            // focus and closes the entire MenuBarExtra popover.
            HStack(spacing: 8) {
                if group.isStaleWorkload {
                    actionButton("结束遗留任务", color: .teal) {
                        store.protection.terminate(group)
                    }
                } else if group.anyStopped {
                    actionButton("恢复任务", color: .accentColor) {
                        store.protection.resume(group)
                    }
                } else {
                    actionButton("暂停任务", color: .accentColor) {
                        store.protection.pause(group)
                    }
                }

                Spacer()

                if terminateArmed {
                    Button {
                        terminateArmed = false
                        store.protection.terminate(group)
                    } label: {
                        Text("确认终止 \(group.displayName)？")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)

                    Button("取消") {
                        terminateArmed = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("终止任务") {
                        terminateArmed = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
        .padding(12)
        .glassSurface(Design.Radius.panel)
    }

    /// Standard bordered button — .glass button style has hit-testing issues
    /// inside MenuBarExtra popover windows.
    private func actionButton(_ title: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(color)
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
