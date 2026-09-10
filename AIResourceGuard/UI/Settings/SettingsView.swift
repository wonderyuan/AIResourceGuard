import SwiftUI
import UniformTypeIdentifiers

/// macOS-native settings: sidebar navigation + detail pages.
/// Liquid Glass stays where the system puts it (sidebar, controls); content
/// pages are plain forms with generous spacing — no card grids.
struct SettingsView: View {
    enum Section: String, Hashable, Identifiable, CaseIterable {
        case protection, apps, history, general, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .protection: return "保护方式"
            case .apps: return "每个应用"
            case .history: return "历史记录"
            case .general: return "通用"
            case .about: return "关于"
            }
        }

        var symbol: String {
            switch self {
            case .protection: return "shield.lefthalf.filled"
            case .apps: return "square.grid.2x2"
            case .history: return "clock.arrow.circlepath"
            case .general: return "gearshape"
            case .about: return "info.circle"
            }
        }
    }

    @State private var section: Section = .protection

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
        } detail: {
            Group {
                switch section {
                case .protection: ProtectionPage()
                case .apps: AppsPage()
                case .history: HistoryPage()
                case .general: GeneralPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 800, height: 580)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - 通用

private struct GeneralPage: View {
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
            }

            Section {
                Picker("菜单栏显示", selection: $settings.settings.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("菜单栏")
            } footer: {
                Text("正常状态下尽量克制，只在真正使用时占菜单栏空间；无论哪种模式，异常都会通过图标颜色变化提醒。")
                    .font(.caption2)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 保护方式

/// The operation model: HOW to protect (mode), HOW HARD (intensity), with
/// raw numbers tucked into 高级设置 — not a wall of steppers.
private struct ProtectionPage: View {
    @EnvironmentObject var settings: SettingsStore

    /// 0 = 仅观察, 1 = 自动暂停, 2 = 紧急终止能力.
    private var mode: Int {
        if settings.settings.emergencyKillEnabled { return 2 }
        return settings.settings.autoProtectionEnabled ? 1 : 0
    }

    var body: some View {
        Form {
            Section {
                Picker("保护方式", selection: Binding(
                    get: { mode },
                    set: { applyMode($0) })) {
                    Text("仅观察").tag(0)
                    Text("自动暂停").tag(1)
                    Text("紧急终止").tag(2)
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text(modeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("出事的时候，允许它做到哪一步")
            }

            Section {
                Picker("反应强度", selection: sensitivityBinding) {
                    Text("宽松").tag(Sensitivity.relaxed)
                    Text("推荐").tag(Sensitivity.recommended)
                    Text("灵敏").tag(Sensitivity.sensitive)
                }
                .pickerStyle(.segmented)
                if settings.settings.thresholds.sensitivity == .custom {
                    Label("当前为自定义配置", systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("强度")
            } footer: {
                Text("决定多快升级风险、多早出手。「宽松」适合长期高负载，「灵敏」适合内存常年紧张的机器。")
                    .font(.caption2)
            }

            Section {
                DisclosureGroup("高级设置") {
                    AdvancedThresholdsView()
                }
                .font(.callout)
            } footer: {
                Text("手动调整后强度会变为「自定义」。")
                    .font(.caption2)
            }
        }
        .formStyle(.grouped)
    }

    private var modeDescription: String {
        switch mode {
        case 0:
            return "只提醒，不动作。系统濒临失控时你会收到通知，由你自己决定怎么处理。"
        case 1:
            return "系统濒临失控时，自动暂停「每个应用」里设为自动暂停的应用。会避开你正在使用的应用，压力回落后逐步恢复。"
        default:
            return "在自动暂停之上：若「即将失控」持续一段时间，对单独允许的应用先温和请求退出，仍无响应才强制结束。系统进程永远不会被自动处理。"
        }
    }

    private func applyMode(_ newMode: Int) {
        switch newMode {
        case 0:
            settings.settings.autoProtectionEnabled = false
            settings.settings.emergencyKillEnabled = false
        case 1:
            settings.settings.autoProtectionEnabled = true
            settings.settings.emergencyKillEnabled = false
        default:
            settings.settings.autoProtectionEnabled = true
            settings.settings.emergencyKillEnabled = true
        }
    }

    private var sensitivityBinding: Binding<Sensitivity> {
        Binding(
            get: { settings.settings.thresholds.sensitivity == .custom
                    ? .recommended : settings.settings.thresholds.sensitivity },
            set: { choice in
                if let preset = ThresholdConfig.preset(choice) {
                    settings.settings.thresholds = preset
                    settings.settings.thresholds.sensitivity = choice
                }
            })
    }
}

// MARK: - 应用管理

private struct AppsPage: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter
    @State private var dropFeedback: String?

    var body: some View {
        List {
            Section("设定每个应用的处理方式") {
                if settings.settings.managedApps.isEmpty {
                    Text("还没有应用加入管理。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach($settings.settings.managedApps) { $managed in
                    ManagedAppRow(managed: $managed)
                }
            }

            Section("从正在运行的应用添加") {
                let candidates = store.groups.filter { group in
                    !settings.settings.managedApps.contains { $0.key == group.key }
                        && group.totalFootprint > 10 * 1_048_576
                }
                if candidates.isEmpty {
                    Text("当前没有新的应用。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { group in
                        HStack(spacing: 10) {
                            AppIconView(path: group.iconPath)
                            Text(group.displayName)
                            Spacer()
                            Button("托管") {
                                settings.addManaged(key: group.key,
                                                    displayName: group.displayName,
                                                    iconPath: group.iconPath)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                Label("将应用拖到这里添加", systemImage: "plus.square.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                if let dropFeedback {
                    Text(dropFeedback).font(.caption2).foregroundStyle(.secondary)
                }
            } header: {
                Text("添加应用")
            }

            ProtectedSection()
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        var added = false
        for url in urls {
            let path = url.path
            guard path.contains(".app"),
                  FileManager.default.fileExists(atPath: path) else { continue }
            let bundleName = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
            guard !bundleName.isEmpty else { continue }
            let group = ProcessTreeAggregator.appGroup(forBundle: bundleName)
            settings.addManaged(key: group.key, displayName: group.display, iconPath: path)
            added = true
            dropFeedback = "已添加 \(group.display)"
        }
        if !added { dropFeedback = "只能拖入 .app 应用" }
        return added
    }
}

private struct ManagedAppRow: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter
    @Binding var managed: ManagedAppConfig

    /// 0 = 观察, 1 = 自动暂停, 2 = 自动暂停＋紧急终止.
    private var policy: Int {
        managed.allowEmergencyTerminate ? 2 : (managed.allowAutoPause ? 1 : 0)
    }

    private var iconPath: String? {
        managed.iconPath
            ?? store.groups.first { $0.key == managed.key }?.iconPath
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(path: iconPath)
            VStack(alignment: .leading, spacing: 2) {
                Text(managed.displayName).font(.callout)
                Text(policyText).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button("只观察") { apply(0) }
                Button("濒临失控时自动暂停") { apply(1) }
                Button("自动暂停，且允许紧急终止") { apply(2) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            Button {
                settings.removeManaged(key: managed.key)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("移除")
        }
        .padding(.vertical, 2)
    }

    private var policyText: String {
        switch policy {
        case 0: return "只观察"
        case 1: return "濒临失控时自动暂停"
        default: return "自动暂停，且允许紧急终止"
        }
    }

    private func apply(_ value: Int) {
        switch value {
        case 0:
            managed.allowAutoPause = false
            managed.allowEmergencyTerminate = false
        case 1:
            managed.allowAutoPause = true
            managed.allowEmergencyTerminate = false
        default:
            managed.allowAutoPause = true
            managed.allowEmergencyTerminate = true
        }
    }
}

/// Real app icon when a bundle path is known, generic symbol otherwise.
struct AppIconView: View {
    let path: String?

    var body: some View {
        Group {
            if let path, let image = IconCache.shared.icon(for: path) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct ProtectedSection: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        Section("受保护应用（永不自动处理）") {
            Text("内核、登录、窗口服务等系统进程与所有 root 进程始终受保护。下面是你额外指定的应用：")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(settings.settings.protectedApps, id: \.self) { key in
                HStack {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(displayName(for: key))
                    Spacer()
                    Button {
                        settings.removeProtected(key: key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            let candidates = store.groups.filter {
                !settings.settings.protectedApps.contains($0.key)
                    && $0.totalFootprint > 10 * 1_048_576
            }
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates) { group in
                        Button(group.displayName) {
                            settings.addProtected(key: group.key)
                        }
                    }
                } label: {
                    Label("添加保护", systemImage: "plus")
                        .controlSize(.small)
                }
                .menuStyle(.borderlessButton)
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

private struct AdvancedThresholdsView: View {
    @EnvironmentObject var settings: SettingsStore

    /// Edits through these bindings mark the profile as 自定义.
    private func adv<T: Equatable>(_ keyPath: WritableKeyPath<ThresholdConfig, T>) -> Binding<T> {
        Binding(
            get: { settings.settings.thresholds[keyPath: keyPath] },
            set: { value in
                settings.settings.thresholds[keyPath: keyPath] = value
                settings.settings.thresholds.sensitivity = .custom
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("风险分数（0–1）").font(.caption).foregroundStyle(.secondary)
                sliderRow("注意", adv(\.warningScore))
                sliderRow("压力较高", adv(\.dangerScore))
                sliderRow("即将失控", adv(\.criticalScore))
                Stepper("恢复裕度 \(settings.settings.thresholds.deescalationMargin, specifier: "%.2f")",
                        value: adv(\.deescalationMargin), in: 0.02...0.4, step: 0.02)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("持续时间与通知").font(.caption).foregroundStyle(.secondary)
                Stepper("注意持续 \(Int(settings.settings.thresholds.sustainWarningSeconds)) 秒",
                        value: adv(\.sustainWarningSeconds), in: 2...60)
                Stepper("压力较高持续 \(Int(settings.settings.thresholds.sustainDangerSeconds)) 秒",
                        value: adv(\.sustainDangerSeconds), in: 2...60)
                Stepper("即将失控持续 \(Int(settings.settings.thresholds.sustainCriticalSeconds)) 秒",
                        value: adv(\.sustainCriticalSeconds), in: 2...60)
                Stepper("恢复判定窗口 \(Int(settings.settings.thresholds.deescalateSeconds)) 秒",
                        value: adv(\.deescalateSeconds), in: 5...180, step: 5)
                Stepper("通知冷却 \(Int(settings.settings.thresholds.notifyCooldownSeconds)) 秒",
                        value: adv(\.notifyCooldownSeconds), in: 30...600, step: 30)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Swap 阈值（MB / MB 每分钟）").font(.caption).foregroundStyle(.secondary)
                Stepper("Swap 注意 \(Int(settings.settings.thresholds.swapWarnMB)) MB",
                        value: adv(\.swapWarnMB), in: 256...8192, step: 256)
                Stepper("Swap 压力较高 \(Int(settings.settings.thresholds.swapDangerMB)) MB",
                        value: adv(\.swapDangerMB), in: 512...16384, step: 256)
                Stepper("Swap 即将失控 \(Int(settings.settings.thresholds.swapCriticalMB)) MB",
                        value: adv(\.swapCriticalMB), in: 1024...32768, step: 512)
                Stepper("增速注意 \(Int(settings.settings.thresholds.swapRateWarnMBPerMin)) MB/分钟",
                        value: adv(\.swapRateWarnMBPerMin), in: 25...2000, step: 25)
                Stepper("增速压力较高 \(Int(settings.settings.thresholds.swapRateDangerMBPerMin)) MB/分钟",
                        value: adv(\.swapRateDangerMBPerMin), in: 50...4000, step: 50)
                Stepper("增速即将失控 \(Int(settings.settings.thresholds.swapRateCriticalMBPerMin)) MB/分钟",
                        value: adv(\.swapRateCriticalMBPerMin), in: 100...8000, step: 100)
            }

            Button("恢复默认值") {
                settings.settings.thresholds = ThresholdConfig()
            }
        }
        .padding(.vertical, 4)
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0.1...0.95, step: 0.01)
                .controlSize(.small)
        }
    }
}

// MARK: - 关于

private struct AboutPage: View {
    @EnvironmentObject var store: MonitorCenter

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("内存守护 · AI Resource Guard").font(.title3).fontWeight(.semibold)
                        Text("版本 \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("为在 Mac 上运行 AI 开发任务而设计的菜单栏守护工具：提前发现内存恶化趋势，在系统卡死之前安全地暂停失控任务，并在事后给出完整的事故报告。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("运行状态") {
                LabeledContent("当前风险") {
                    Text(store.assessment.level.label)
                        .foregroundStyle(store.assessment.level.color)
                }
                LabeledContent("内存压力") {
                    Text(store.pressureLevel.label)
                        .foregroundStyle(store.pressureLevel.color)
                }
                if let stats = store.scanStats {
                    LabeledContent("进程归因") {
                        Text("\(stats.rusageReads)/\(stats.totalPids) 可读取")
                            .foregroundStyle(stats.failureRatio > 0.3 ? .orange : .secondary)
                    }
                    LabeledContent("归因覆盖") {
                        Text("\(Int(store.notableContext.attributionCoverage * 100))% 已用内存")
                            .foregroundStyle(
                                store.notableContext.attributionIncomplete ? .orange : .secondary)
                    }
                }
                LabeledContent("本机基线") {
                    Text(store.baselineReady ? "已就绪" : "学习中")
                        .foregroundStyle(.secondary)
                }
            }

            Section("源代码") {
                Text("github.com/wonderyuan/AIResourceGuard")
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
