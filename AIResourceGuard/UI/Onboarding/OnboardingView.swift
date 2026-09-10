import SwiftUI
import AppKit

/// First-launch onboarding: what the guard does, notifications, and the
/// protection mode — once, then never again.
enum Onboarding {
    private static let flagKey = "local.dev.AIResourceGuard.onboarded.v1"

    static var shouldShow: Bool {
        UserDefaults.standard.bool(forKey: flagKey) == false
    }

    static func markComplete() {
        UserDefaults.standard.set(true, forKey: flagKey)
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "欢迎使用内存守护"
        window.contentView = NSHostingView(rootView:
            OnboardingView()
                .environmentObject(MonitorCenter.shared)
                .environmentObject(MonitorCenter.shared.settingsStore))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController is created via shared")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    override func close() {
        window?.close()
    }
}

private struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var step = 0
    @State private var chosenMode = 0 // 0 观察 / 1 自动暂停

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                intro.tag(0)
                notification.tag(1)
                mode.tag(2)
            }
            .tabViewStyle(.automatic)
            .padding(Design.Space.xl)

            Divider()

            HStack {
                if step > 0 {
                    Button("上一步") { withAnimation(Design.Motion.standard) { step -= 1 } }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if step < 2 {
                    Button(step == 0 ? "继续" : "开始使用") {
                        withAnimation(Design.Motion.standard) { step += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("开始使用") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Design.Space.l)
        }
        .frame(width: 480, height: 400)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("它会守住你的内存")
                .font(Design.Typo.title)
            Text("在 Cursor、Xcode、模拟器、MCP 服务这些任务把内存吃光之前提醒你，告诉你谁在占用、为什么紧张，并在你允许时安全地暂停失控的任务——系统进程永远不会被碰。")
                .font(Design.Typo.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notification: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Image(systemName: "bell.badge")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("值得打断你的时刻")
                .font(Design.Typo.title)
            Text("平时它保持安静，只在菜单栏显示状态。当 Swap 快速增长、系统濒临失控时，通知会告诉你原因和建议——这时出手，远比卡死后再重启来得及。")
                .font(Design.Typo.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mode: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Image(systemName: "hand.raised")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
            Text("先从只观察开始？")
                .font(Design.Typo.title)
            Picker("保护方式", selection: $chosenMode) {
                Text("只观察，出事只提醒我").tag(0)
                Text("允许自动暂停我选的应用").tag(1)
            }
            .pickerStyle(.radioGroup)
            Text("随时可以在设置里调整；自动暂停只会作用于你明确选择的应用，并且永远避开你正在使用的应用。")
                .font(Design.Typo.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finish() {
        switch chosenMode {
        case 1:
            settings.settings.autoProtectionEnabled = true
        default:
            settings.settings.autoProtectionEnabled = false
        }
        settings.settings.emergencyKillEnabled = false
        Onboarding.markComplete()
        Notifier.shared.requestIfNeeded()
        OnboardingWindowController.shared.close()
    }
}
