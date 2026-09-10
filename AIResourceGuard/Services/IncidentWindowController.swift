import AppKit
import SwiftUI

/// Standalone window showing the post-mortem incident report. Opened by the
/// menu-bar popover, the Window menu, or a notification click. A plain
/// NSWindow (not a SwiftUI scene) because MenuBarExtra popovers cannot be
/// opened programmatically and this window must be openable from anywhere.
@MainActor
final class IncidentWindowController: NSWindowController, NSWindowDelegate {
    static let shared = IncidentWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Incident Report"
        window.contentView = NSHostingView(rootView:
            IncidentReportView()
                .environmentObject(MonitorCenter.shared)
                .environmentObject(MonitorCenter.shared.settingsStore))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("IncidentWindowController is created via shared")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
