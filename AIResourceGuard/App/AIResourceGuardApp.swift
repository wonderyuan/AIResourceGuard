import SwiftUI

@main
struct AIResourceGuardApp: App {
    @StateObject private var store = MonitorCenter.shared
    @StateObject private var settings = MonitorCenter.shared.settingsStore

    init() {
        if CommandLine.arguments.contains("--diagnostics") {
            DiagnosticsRunner.run(seconds: 25)
        }
        let isTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTest {
            MonitorCenter.shared.start()
        }
        // Dev hook: render the popover content in a plain window so it can be
        // inspected without clicking the menu-bar icon.
        if CommandLine.arguments.contains("--ui-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                UIPreviewWindowController.shared.show()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(store)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .commands {
            CommandGroup(after: .windowList) {
                Button("事件报告…") {
                    IncidentWindowController.shared.show()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}

/// `--ui-preview`: opens a window hosting the exact popover content — used to
/// verify the primary surface without menu-bar interaction.
@MainActor
final class UIPreviewWindowController: NSWindowController {
    static let shared = UIPreviewWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "内存守护（预览）"
        window.contentView = NSHostingView(rootView:
            DashboardView()
                .environmentObject(MonitorCenter.shared)
                .environmentObject(MonitorCenter.shared.settingsStore))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("UIPreviewWindowController is created via shared")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
