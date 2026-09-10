import SwiftUI

@main
struct AIResourceGuardApp: App {
    @StateObject private var store = MonitorCenter.shared
    @StateObject private var settings = MonitorCenter.shared.settingsStore

    init() {
        if CommandLine.arguments.contains("--diagnostics") {
            DiagnosticsRunner.run(seconds: 25)
        }
        // Never start monitors while running under the test host.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            MonitorCenter.shared.start()
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
                Button("Incident Report") {
                    IncidentWindowController.shared.show()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}
