import SwiftUI

/// One row in "谁在占用内存". Collapsed: name, memory, trend, CPU, tags.
/// Expanded: process tree + 暂停/恢复/终止. Paused groups dim to gray.
///
/// Interaction notes:
/// - No confirmationDialog/alert — in MenuBarExtra they dismiss the popover.
/// - No ScrollView around the list — ScrollView in MenuBarExtra windows
///   intercepts button clicks on macOS 26 (verified by user testing).
/// - All buttons use .bordered style + .contentShape(Rectangle()) for
///   reliable hit testing.
struct ProcessGroupRow: View {
    let group: ProcessGroupInfo

    @EnvironmentObject var store: MonitorCenter
    @State private var expanded = false
    @State private var terminateArmed = false

    private var isProtected: Bool {
        store.settingsStore.isProtectedGroup(group.key)
    }

    /// Visual state for paused groups.
    private var isPaused: Bool { group.anyStopped }

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
            }
            .buttonStyle(.plain)

            if expanded {
                detail
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        // Paused groups dim to visually communicate their state.
        .opacity(isPaused ? 0.55 : 1.0)
        .saturation(isPaused ? 0.3 : 1.0)
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

            // Action bar — prominent, always visible when expanded.
            HStack(spacing: 10) {
                if terminateArmed {
                    confirmTerminate
                } else {
                    // Primary action: pause or resume
                    Button {
                        if isPaused {
                            store.protection.resume(group)
                        } else {
                            store.protection.pause(group)
                        }
                        store.popoverOpened()
                    } label: {
                        Label(isPaused ? "恢复任务" : "暂停任务",
                              systemImage: isPaused ? "play.fill" : "pause.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(isPaused ? .green : .accentColor)
                    .contentShape(Rectangle())

                    Spacer()

                    Button {
                        terminateArmed = true
                    } label: {
                        Label("终止", systemImage: "xmark")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35),
                    in: .rect(cornerRadius: Design.Radius.panel))
    }

    private var confirmTerminate: some View {
        HStack(spacing: 10) {
            Button {
                terminateArmed = false
                store.protection.terminate(group)
                store.popoverOpened()
            } label: {
                Label("确认终止 \(group.displayName)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(.red)
            .contentShape(Rectangle())

            Button("取消") {
                terminateArmed = false
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .contentShape(Rectangle())

            Spacer()
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
