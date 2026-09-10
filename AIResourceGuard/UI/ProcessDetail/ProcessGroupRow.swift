import SwiftUI

/// One aggregated process group row in "Top Consumers". Click to expand the
/// process tree (pid, name, RSS, CPU, paused state) with group-level
/// Pause / Resume / Terminate actions.
struct ProcessGroupRow: View {
    let group: ProcessGroupInfo

    @EnvironmentObject var store: MonitorCenter
    @State private var expanded = false
    @State private var confirmTerminate = false
    @State private var confirmForce = false

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
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(group.displayName)
                                .font(.callout)
                                .lineLimit(1)
                            if isProtected {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("\(group.processes.count) processes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: group.trendDirection.symbol)
                        .font(.caption2)
                        .foregroundStyle(trendColor)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(fmtBytes(group.totalRSS))
                            .font(.callout)
                            .monospacedDigit()
                        Text(cpuText)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
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
        return pct >= 100 ? String(format: "%.0f%% CPU", pct) : String(format: "%.1f%% CPU", pct)
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
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if abs(group.trendBytesPerMin) > 50 * 1_048_576 {
                Text("Trend: \(fmtRate(group.trendBytesPerMin)) (5 min window)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let parentPids = Set(group.processes.map(\.ppid))
            ForEach(Array(group.processes.prefix(12).enumerated()), id: \.element.pid) { _, proc in
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
                        .frame(width: 34, alignment: .trailing)
                }
            }
            if group.processes.count > 12 {
                Text("+ \(group.processes.count - 12) more…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                if group.anyStopped {
                    Button("Resume") { store.protection.resume(group) }
                        .controlSize(.small)
                } else {
                    Button("Pause") { store.protection.pause(group) }
                        .controlSize(.small)
                }
                Spacer()
                Button("Terminate") { confirmTerminate = true }
                    .controlSize(.small)
                    .tint(.red)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
        .confirmationDialog(
            "Terminate \(group.displayName)?",
            isPresented: $confirmTerminate,
            titleVisibility: .visible) {
            Button("Terminate (SIGTERM)", role: .destructive) {
                store.protection.terminate(group)
            }
            Button("Force Quit (SIGKILL)", role: .destructive) {
                confirmForce = false
                store.protection.forceTerminate(group)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends SIGTERM to \(group.processes.count) processes; unsaved work may be lost.")
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
            if group.key.hasPrefix("mcp-") { return "server.rack" }
            return "app.dashed"
        }
    }

    private func loadIcon() {
        guard group.isApp, let path = group.iconPath else { return }
        nsImage = IconCache.shared.icon(for: path)
    }
}
