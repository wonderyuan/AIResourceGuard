import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ManagedAppsTab()
                .tabItem { Label("托管应用", systemImage: "checkmark.shield") }
            ProtectedAppsTab()
                .tabItem { Label("受保护应用", systemImage: "lock.shield") }
            ThresholdsTab()
                .tabItem { Label("阈值", systemImage: "slider.horizontal.3") }
            HistoryView()
                .tabItem { Label("历史记录", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 640, height: 500)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var loginItemError: String?
    @State private var loginItemEnabled = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("登录时启动", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { enabled in
                        switch LaunchAtLogin.setEnabled(enabled) {
                        case .success:
                            loginItemError = nil
                        case .failure(let error):
                            loginItemError = error.localizedDescription
                            loginItemEnabled = false
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("风险通知", isOn: $settings.settings.notificationsEnabled)
            } header: {
                Text("启动")
            } footer: {
                Text("登录启动使用 SMAppService；请将应用放在稳定路径（如 /Applications）。")
                    .font(.caption2)
            }

            Section {
                Toggle("自动保护", isOn: $settings.settings.autoProtectionEnabled)
                Toggle("恢复正常后自动恢复已暂停的任务", isOn: $settings.settings.autoResumeOnNormal)
            } header: {
                Text("保护")
            } footer: {
                Text("达到「即将失控」时，自动暂停你在「托管应用」里明确启用的应用。默认不处理任何应用。")
                    .font(.caption2)
            }

            Section {
                Toggle("紧急终止", isOn: $settings.settings.emergencyKillEnabled)
                Stepper("「即将失控」持续 \(settings.settings.emergencyKillDelaySeconds) 秒后发送 SIGTERM",
                        value: $settings.settings.emergencyKillDelaySeconds, in: 10...300, step: 5)
                Stepper("SIGTERM 宽限 \(settings.settings.emergencyKillGraceSeconds) 秒后才允许 SIGKILL",
                        value: $settings.settings.emergencyKillGraceSeconds, in: 5...120, step: 5)
            } header: {
                Text("紧急终止")
            } footer: {
                Text("SIGKILL 仅作为最后手段，且只对单独启用「紧急终止」的应用生效。系统进程永远不会被自动处理。")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 托管应用

private struct ManagedAppsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        List {
            Section("已托管 — 允许自动处理的对象（默认全部关闭）") {
                ForEach($settings.settings.managedApps) { $managed in
                    ManagedAppRow(managed: $managed)
                }
            }
            Section("检测到的新应用") {
                let unmanaged = detectedUnmanaged
                if unmanaged.isEmpty {
                    Text("当前没有新的应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unmanaged) { group in
                        HStack {
                            Text(group.displayName)
                                .font(.callout)
                            Spacer()
                            Button("托管") {
                                settings.addManaged(key: group.key, displayName: group.displayName)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var detectedUnmanaged: [ProcessGroupInfo] {
        store.groups.filter { group in
            !settings.settings.managedApps.contains { $0.key == group.key }
                && group.totalRSS > 10 * 1_048_576
        }
    }
}

private struct ManagedAppRow: View {
    @EnvironmentObject var settings: SettingsStore
    @Binding var managed: ManagedAppConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(managed.displayName).font(.callout)
                Spacer()
                Button("移除") {
                    settings.removeManaged(key: managed.key)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                Toggle("自动暂停", isOn: $managed.allowAutoPause)
                Toggle("紧急终止", isOn: $managed.allowEmergencyTerminate)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 受保护应用

private struct ProtectedAppsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        List {
            Section("始终受保护（内置，不可关闭）") {
                Text("kernel_task、launchd、WindowServer、loginwindow、Finder、Dock、SystemUIServer 等系统进程；所有 root 进程；/System、/usr/libexec、/usr/sbin、/sbin、/Library/Apple 路径下的进程；以及内存守护自身。这些永远不会被暂停或终止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("你保护的应用") {
                ForEach(settings.settings.protectedApps, id: \.self) { key in
                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(displayName(for: key))
                        Spacer()
                        Button("移除") {
                            settings.removeProtected(key: key)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
                if settings.settings.protectedApps.isEmpty {
                    Text("暂无自定义保护项，可从下方添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("从当前运行的应用中添加") {
                let candidates = store.groups.filter {
                    !settings.settings.protectedApps.contains($0.key) && $0.totalRSS > 10 * 1_048_576
                }
                if candidates.isEmpty {
                    Text("当前没有可添加的应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { group in
                        HStack {
                            Text(group.displayName)
                            Spacer()
                            Button("保护") {
                                settings.addProtected(key: group.key)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func displayName(for key: String) -> String {
        if let managed = settings.settings.managedApps.first(where: { $0.key == key }) {
            return managed.displayName
        }
        if let group = store.groups.first(where: { $0.key == key }) {
            return group.displayName
        }
        return key
    }
}

// MARK: - 阈值

private struct ThresholdsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                sliderRow("注意分数", $settings.settings.thresholds.warningScore)
                sliderRow("压力较高分数", $settings.settings.thresholds.dangerScore)
                sliderRow("即将失控分数", $settings.settings.thresholds.criticalScore)
                Stepper("恢复裕度（滞回）\(settings.settings.thresholds.deescalationMargin, specifier: "%.2f")",
                        value: $settings.settings.thresholds.deescalationMargin, in: 0.02...0.4, step: 0.02)
            } header: {
                Text("风险分数（0–1）")
            }

            Section {
                Stepper("注意持续 \(Int(settings.settings.thresholds.sustainWarningSeconds)) 秒",
                        value: $settings.settings.thresholds.sustainWarningSeconds, in: 2...60)
                Stepper("压力较高持续 \(Int(settings.settings.thresholds.sustainDangerSeconds)) 秒",
                        value: $settings.settings.thresholds.sustainDangerSeconds, in: 2...60)
                Stepper("即将失控持续 \(Int(settings.settings.thresholds.sustainCriticalSeconds)) 秒",
                        value: $settings.settings.thresholds.sustainCriticalSeconds, in: 2...60)
                Stepper("恢复判定窗口 \(Int(settings.settings.thresholds.deescalateSeconds)) 秒",
                        value: $settings.settings.thresholds.deescalateSeconds, in: 5...180, step: 5)
                Stepper("通知冷却 \(Int(settings.settings.thresholds.notifyCooldownSeconds)) 秒",
                        value: $settings.settings.thresholds.notifyCooldownSeconds, in: 30...600, step: 30)
            } header: {
                Text("持续时间与滞回")
            }

            Section {
                Stepper("Swap 注意阈值 \(Int(settings.settings.thresholds.swapWarnMB)) MB",
                        value: $settings.settings.thresholds.swapWarnMB, in: 256...8192, step: 256)
                Stepper("Swap 压力较高阈值 \(Int(settings.settings.thresholds.swapDangerMB)) MB",
                        value: $settings.settings.thresholds.swapDangerMB, in: 512...16384, step: 256)
                Stepper("Swap 即将失控阈值 \(Int(settings.settings.thresholds.swapCriticalMB)) MB",
                        value: $settings.settings.thresholds.swapCriticalMB, in: 1024...32768, step: 512)
                Stepper("增速注意 \(Int(settings.settings.thresholds.swapRateWarnMBPerMin)) MB/分钟",
                        value: $settings.settings.thresholds.swapRateWarnMBPerMin, in: 25...2000, step: 25)
                Stepper("增速压力较高 \(Int(settings.settings.thresholds.swapRateDangerMBPerMin)) MB/分钟",
                        value: $settings.settings.thresholds.swapRateDangerMBPerMin, in: 50...4000, step: 50)
                Stepper("增速即将失控 \(Int(settings.settings.thresholds.swapRateCriticalMBPerMin)) MB/分钟",
                        value: $settings.settings.thresholds.swapRateCriticalMBPerMin, in: 100...8000, step: 100)
            } header: {
                Text("Swap 阈值")
            }

            Button("恢复默认值") {
                settings.settings.thresholds = ThresholdConfig()
            }
        }
        .formStyle(.grouped)
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label)：\(value.wrappedValue, specifier: "%.2f")")
                .font(.caption)
            Slider(value: value, in: 0.1...0.95, step: 0.01)
                .controlSize(.small)
        }
    }
}
