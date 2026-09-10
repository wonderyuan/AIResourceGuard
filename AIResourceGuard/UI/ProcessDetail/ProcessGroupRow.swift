import SwiftUI

/// One row in "值得关注的应用". Collapsed: name, aggregated memory, growth
/// trend, CPU, risk-source tag. Expanded (the key interactive area, on
/// Liquid Glass): process tree + 暂停/恢复/终止.
struct ProcessGroupRow: View {
    let group: ProcessGroupInfo

    @EnvironmentObject var store: MonitorCenter
    @State private var expanded = false
    @State private var confirmTerminate = false

    private var isProtected: Bool {
        store.settingsStore.isProtectedGroup(group.key)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
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
                                Text("风险源")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            if isProtected {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(group.processes.count) 个进程 · CPU \(cpuText)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(trendText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(trendColor)
                    Text(fmtBytes(group.totalRSS))
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

    private var trendText: String {
        let mbMin = group.trendBytesPerMin / 1_048_576
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

    // MARK: - Expanded detail (key interactive area → Liquid Glass)

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
                        Text("MCP")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
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

            HStack(spacing: 8) {
                if group.anyStopped {
                    Button("恢复任务") { store.protection.resume(group) }
                        .glassActionButton()
                        .controlSize(.small)
                } else {
                    Button("暂停任务") { store.protection.pause(group) }
                        .glassActionButton()
                        .controlSize(.small)
                }
                Spacer()
                Button("终止任务") { confirmTerminate = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }
        }
        .padding(12)
        .glassSurface()
        .confirmationDialog(
            "终止 \(group.displayName)？",
            isPresented: $confirmTerminate,
            titleVisibility: .visible) {
            Button("终止任务（SIGTERM）", role: .destructive) {
                store.protection.terminate(group)
            }
            Button("强制退出（SIGKILL）", role: .destructive) {
                store.protection.forceTerminate(group)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将向 \(group.processes.count) 个进程发送 SIGTERM，未保存的工作可能丢失。")
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
