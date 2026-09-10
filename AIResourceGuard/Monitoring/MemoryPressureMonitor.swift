import Foundation

/// Kernel memory-pressure transitions via the public dispatch source
/// (`DispatchSource.makeMemoryPressureSource`, available since macOS 10.9).
/// Events arrive instantly on transitions between normal/warning/critical.
final class MemoryPressureMonitor {
    var onEvent: ((PressureLevel) -> Void)?

    private(set) var level: PressureLevel = .normal
    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "local.dev.AIResourceGuard.pressure", qos: .utility)

    func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let event = src.data
            let level: PressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            self.level = level
            self.onEvent?(level)
        }
        src.activate()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
