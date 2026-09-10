import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ManagedAppsTab()
                .tabItem { Label("Managed Apps", systemImage: "checkmark.shield") }
            ProtectedAppsTab()
                .tabItem { Label("Protected Apps", systemImage: "lock.shield") }
            ThresholdsTab()
                .tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 480)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var loginItemError: String?
    @State private var loginItemEnabled = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $loginItemEnabled)
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
                Toggle("Notifications", isOn: $settings.settings.notificationsEnabled)
            } header: {
                Text("Startup")
            } footer: {
                Text("Launch at Login uses SMAppService; keep the app at a stable path (e.g. /Applications).")
                    .font(.caption2)
            }

            Section {
                Toggle("Auto Protection", isOn: $settings.settings.autoProtectionEnabled)
                Toggle("Auto-resume paused apps when back to Normal", isOn: $settings.settings.autoResumeOnNormal)
            } header: {
                Text("Protection")
            } footer: {
                Text("When risk reaches Critical, apps you explicitly enabled in Managed Apps are paused with SIGSTOP. Nothing is ever touched by default.")
                    .font(.caption2)
            }

            Section {
                Toggle("Emergency Terminate", isOn: $settings.settings.emergencyKillEnabled)
                Stepper("Sustained Critical before SIGTERM: \(settings.settings.emergencyKillDelaySeconds)s",
                        value: $settings.settings.emergencyKillDelaySeconds, in: 10...300, step: 5)
                Stepper("SIGTERM grace before SIGKILL: \(settings.settings.emergencyKillGraceSeconds)s",
                        value: $settings.settings.emergencyKillGraceSeconds, in: 5...120, step: 5)
            } header: {
                Text("Emergency Terminate")
            } footer: {
                Text("SIGKILL is a last resort after the grace period, and only for apps with “Allow Emergency Terminate” enabled. Automatic force-kill is never performed on anything else.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Managed apps

private struct ManagedAppsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        List {
            Section("Managed — apps this app may act on (nothing is enabled by default)") {
                ForEach($settings.settings.managedApps) { $managed in
                    ManagedAppRow(managed: $managed)
                }
            }
            Section("Detected groups not yet managed") {
                let unmanaged = detectedUnmanaged
                if unmanaged.isEmpty {
                    Text("Nothing new detected right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(unmanaged) { group in
                        HStack {
                            Text(group.displayName)
                                .font(.callout)
                            Spacer()
                            Button("Manage") {
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
                Button("Remove") {
                    settings.removeManaged(key: managed.key)
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                Toggle("Auto Pause", isOn: $managed.allowAutoPause)
                Toggle("Emergency Terminate", isOn: $managed.allowEmergencyTerminate)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Protected apps

private struct ProtectedAppsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        List {
            Section("Always protected (built-in)") {
                Text("kernel_task, launchd, WindowServer, loginwindow, Finder, Dock, SystemUIServer, all root-owned processes, everything under /System, /usr/libexec, /usr/sbin, /sbin, /Library/Apple — and AI Resource Guard itself. These can never be paused or terminated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Your protected apps") {
                ForEach(settings.settings.protectedApps, id: \.self) { key in
                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(displayName(for: key))
                        Spacer()
                        Button("Remove") {
                            settings.removeProtected(key: key)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
                if settings.settings.protectedApps.isEmpty {
                    Text("No custom protected apps. Add any detected group below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Add from currently running groups") {
                let candidates = store.groups.filter {
                    !settings.settings.protectedApps.contains($0.key) && $0.totalRSS > 10 * 1_048_576
                }
                if candidates.isEmpty {
                    Text("No candidates right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { group in
                        HStack {
                            Text(group.displayName)
                            Spacer()
                            Button("Protect") {
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

// MARK: - Thresholds

private struct ThresholdsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                sliderRow("Warning score", $settings.settings.thresholds.warningScore)
                sliderRow("Danger score", $settings.settings.thresholds.dangerScore)
                sliderRow("Critical score", $settings.settings.thresholds.criticalScore)
                Stepper("De-escalation margin: \(settings.settings.thresholds.deescalationMargin, specifier: "%.2f")",
                        value: $settings.settings.thresholds.deescalationMargin, in: 0.02...0.4, step: 0.02)
            } header: {
                Text("Risk scores (0–1)")
            }

            Section {
                Stepper("Warning sustain: \(Int(settings.settings.thresholds.sustainWarningSeconds))s",
                        value: $settings.settings.thresholds.sustainWarningSeconds, in: 2...60)
                Stepper("Danger sustain: \(Int(settings.settings.thresholds.sustainDangerSeconds))s",
                        value: $settings.settings.thresholds.sustainDangerSeconds, in: 2...60)
                Stepper("Critical sustain: \(Int(settings.settings.thresholds.sustainCriticalSeconds))s",
                        value: $settings.settings.thresholds.sustainCriticalSeconds, in: 2...60)
                Stepper("De-escalation window: \(Int(settings.settings.thresholds.deescalateSeconds))s",
                        value: $settings.settings.thresholds.deescalateSeconds, in: 5...180, step: 5)
                Stepper("Notification cooldown: \(Int(settings.settings.thresholds.notifyCooldownSeconds))s",
                        value: $settings.settings.thresholds.notifyCooldownSeconds, in: 30...600, step: 30)
            } header: {
                Text("Sustain / hysteresis")
            }

            Section {
                Stepper("Swap warn: \(Int(settings.settings.thresholds.swapWarnMB)) MB",
                        value: $settings.settings.thresholds.swapWarnMB, in: 256...8192, step: 256)
                Stepper("Swap danger: \(Int(settings.settings.thresholds.swapDangerMB)) MB",
                        value: $settings.settings.thresholds.swapDangerMB, in: 512...16384, step: 256)
                Stepper("Swap critical: \(Int(settings.settings.thresholds.swapCriticalMB)) MB",
                        value: $settings.settings.thresholds.swapCriticalMB, in: 1024...32768, step: 512)
                Stepper("Swap rate warn: \(Int(settings.settings.thresholds.swapRateWarnMBPerMin)) MB/min",
                        value: $settings.settings.thresholds.swapRateWarnMBPerMin, in: 25...2000, step: 25)
                Stepper("Swap rate danger: \(Int(settings.settings.thresholds.swapRateDangerMBPerMin)) MB/min",
                        value: $settings.settings.thresholds.swapRateDangerMBPerMin, in: 50...4000, step: 50)
                Stepper("Swap rate critical: \(Int(settings.settings.thresholds.swapRateCriticalMBPerMin)) MB/min",
                        value: $settings.settings.thresholds.swapRateCriticalMBPerMin, in: 100...8000, step: 100)
            } header: {
                Text("Swap")
            }

            Button("Reset to defaults") {
                settings.settings.thresholds = ThresholdConfig()
            }
        }
        .formStyle(.grouped)
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue, specifier: "%.2f")")
                .font(.caption)
            Slider(value: value, in: 0.1...0.95, step: 0.01)
                .controlSize(.small)
        }
    }
}
