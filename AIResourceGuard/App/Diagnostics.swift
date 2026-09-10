import Foundation

/// Headless validation mode: `AI Resource Guard.app/Contents/MacOS/"AI Resource Guard" --diagnostics`
/// runs the full monitoring pipeline for a few seconds, prints one line per
/// system tick, then exits. Used to verify real system data without UI.
enum DiagnosticsRunner {
    @MainActor
    static func run(seconds: TimeInterval) -> Never {
        let store = MonitorCenter.shared
        let startedAt = Date()
        var sampleCount = 0
        store.debugSink = { line in
            print(line)
            sampleCount += 1
        }
        store.start(notifications: false)

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }

        print("diagnostics: \(sampleCount) system samples in "
            + String(format: "%.0f", Date().timeIntervalSince(startedAt)) + "s")
        exit(0)
    }
}
