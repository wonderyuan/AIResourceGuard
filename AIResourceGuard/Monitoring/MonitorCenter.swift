import Foundation
import Combine
import os

private let log = Logger(subsystem: "local.dev.AIResourceGuard", category: "center")

/// Central orchestrator (main actor). Owns the monitors, merges samples,
/// runs the RiskEngine, drives adaptive cadence, records history and hands
/// assessments to the ProtectionController. Published state feeds the menu
/// bar icon and popover; heavy publishes are throttled while hidden.
@MainActor
final class MonitorCenter: ObservableObject {
    static let shared = MonitorCenter()

    @Published private(set) var system: SystemSample?
    @Published private(set) var groups: [ProcessGroupInfo] = []
    /// Curated "值得关注的应用" — risk sources first, then stable heavies.
    @Published private(set) var notableApps: [ProcessGroupInfo] = []
    @Published private(set) var assessment = RiskAssessment.initial
    @Published private(set) var pressureLevel: PressureLevel = .normal
    @Published private(set) var actionFeedback: [ActionFeedback] = []
    @Published var popoverVisible = false

    struct ActionFeedback: Identifiable {
        let id = UUID()
        let text: String
        let date = Date()
    }

    let settingsStore: SettingsStore
    let history = HistoryStore.shared
    let riskEngine = RiskEngine()
    let protection: ProtectionController

    /// Headless diagnostics output (one line per system tick).
    var debugSink: ((String) -> Void)?

    private let pressureMonitor = MemoryPressureMonitor()
    private let systemMonitor = SystemMetricsMonitor()
    private let processMonitor = ProcessMonitor()

    private var started = false
    private var latestGroups: [ProcessGroupInfo] = []
    private var fastestGrowing: (name: String, bytesPerMin: Double)?
    private var lastSnapshotAt: Date?
    private var lastHiddenPublishAt = Date.distantPast

    private init() {
        let settingsStore = SettingsStore()
        self.settingsStore = settingsStore
        riskEngine.thresholdsProvider = { [weak settingsStore] in
            settingsStore?.settings.thresholds ?? ThresholdConfig()
        }
        protection = ProtectionController(
            settingsProvider: { [weak settingsStore] in
                settingsStore?.settings ?? AppSettings()
            },
            policyProvider: { ProtectedProcessPolicy(selfPid: getpid()) },
            history: history)
    }

    func start(notifications: Bool = true) {
        guard !started else { return }
        started = true
        log.info("AI Resource Guard starting")
        history.record(HistoryEvent(kind: "launch", summary: "内存守护已启动"))

        Notifier.shared.onOpenIncident = {
            IncidentWindowController.shared.show()
        }
        protection.onFeedback = { [weak self] text in
            self?.pushFeedback(text)
        }

        pressureMonitor.onEvent = { [weak self] level in
            DispatchQueue.main.async { self?.handlePressure(level) }
        }
        systemMonitor.onSample = { [weak self] sample in
            DispatchQueue.main.async { self?.handleSystem(sample) }
        }
        processMonitor.onScan = { [weak self] output in
            DispatchQueue.main.async { self?.handleProcess(output) }
        }

        pressureMonitor.start()
        systemMonitor.start(interval: 5)
        processMonitor.start(interval: 20)
        if notifications { Notifier.shared.requestIfNeeded() }
        checkPreviousSessionEnd()
    }

    /// Called by the popover as soon as it appears: refresh immediately.
    func popoverOpened() {
        popoverVisible = true
        systemMonitor.sampleNow()
        processMonitor.scanNow()
    }

    // MARK: - Event handling

    private func pushFeedback(_ text: String) {
        actionFeedback.insert(ActionFeedback(text: text), at: 0)
        if actionFeedback.count > 5 {
            actionFeedback = Array(actionFeedback.prefix(5))
        }
    }

    private func handlePressure(_ level: PressureLevel) {
        let old = pressureLevel
        pressureLevel = level
        systemMonitor.currentPressure = level
        if old != level {
            history.record(HistoryEvent(
                kind: "pressureChange",
                summary: "内存压力：\(old.label) → \(level.label)"))
            log.info("Pressure \(old.label) -> \(level.label)")
        }
        systemMonitor.sampleNow()
    }

    private func handleSystem(_ sample: SystemSample) {
        system = sample

        let input = RiskInput(
            timestamp: sample.timestamp,
            pressure: pressureLevel,
            memoryUsedFraction: sample.usedFraction,
            swapUsedBytes: sample.swapUsedBytes,
            swapRateBytesPerMin: sample.swapRateBytesPerMin,
            pageoutRate: sample.pageoutRate,
            decompressionRate: sample.decompressionRate,
            topGrowthBytesPerMin: fastestGrowing?.bytesPerMin ?? 0,
            topGrowthGroup: fastestGrowing?.name)

        let result = riskEngine.evaluate(input)
        assessment = result

        if result.justEscalated || result.justDeescalated {
            history.record(HistoryEvent(
                kind: "riskChange",
                summary: "风险：\(result.previousLevel.label) → \(result.level.label)"
                    + " — \(result.headline)",
                detail: result.reasons.joined(separator: "\n")))
            log.info("Risk \(result.previousLevel.label) -> \(result.level.label)")
        }

        if result.shouldNotify && settingsStore.settings.notificationsEnabled {
            var body = result.headline
            if !result.reasons.isEmpty {
                body += "。" + result.reasons.prefix(2).joined(separator: "，")
            }
            if result.level >= .danger, let fastest = fastestGrowing {
                body += "。增长最快：\(fastest.name)"
            } else if result.level == .warning {
                let top = latestGroups.prefix(3)
                    .map { "\($0.displayName) \(fmtBytes($0.totalRSS))" }
                    .joined(separator: "、")
                if !top.isEmpty { body += "。占用最高：\(top)" }
            }
            Notifier.shared.notify(
                title: "内存守护 — \(result.level.label)",
                body: body,
                openIncident: true)
        }

        protection.handleAssessment(result, groups: latestGroups)

        // Adaptive cadence: metrics 5/2/1s, process scan 20/10/5s.
        let metricsInterval: TimeInterval
        let scanInterval: TimeInterval
        switch result.level {
        case .normal: metricsInterval = 5; scanInterval = 20
        case .warning: metricsInterval = 2; scanInterval = 10
        case .danger, .critical: metricsInterval = 1; scanInterval = 5
        }
        systemMonitor.setInterval(metricsInterval)
        processMonitor.setInterval(scanInterval)

        // Periodic snapshot for post-mortem history.
        let snapshotInterval: TimeInterval = result.level == .normal ? 120
            : result.level == .warning ? 60 : 30
        if lastSnapshotAt == nil
            || Date().timeIntervalSince(lastSnapshotAt!) >= snapshotInterval {
            lastSnapshotAt = Date()
            recordSnapshot(sample, assessment: result)
        }

        debugSink?(diagnosticsLine(sample, assessment: result))
    }

    private func handleProcess(_ output: ProcessMonitor.Output) {
        latestGroups = output.groups
        fastestGrowing = output.fastestGrowing
        let notable = computeNotable(output.groups)

        // Skip expensive UI publishes while the popover is closed.
        if popoverVisible || Date().timeIntervalSince(lastHiddenPublishAt) > 15 {
            groups = output.groups
            notableApps = notable
            lastHiddenPublishAt = Date()
        }
    }

    /// "值得关注的应用" selection — explicitly NOT top-by-RSS:
    /// 1. groups actively growing (> 50 MB/min = 风险源), worst growth first;
    /// 2. then stable heavy residents (> 300 MB), largest first.
    private func computeNotable(_ groups: [ProcessGroupInfo]) -> [ProcessGroupInfo] {
        let riskThreshold = 50.0 * 1_048_576
        let sizeFloor = 300.0 * 1_048_576
        let candidates = groups.filter {
            Double($0.totalRSS) > sizeFloor || $0.trendBytesPerMin > riskThreshold
        }
        return candidates
            .sorted { lhs, rhs in
                let lhsRisk = lhs.trendBytesPerMin > riskThreshold
                let rhsRisk = rhs.trendBytesPerMin > riskThreshold
                if lhsRisk != rhsRisk { return lhsRisk }
                if lhsRisk { return lhs.trendBytesPerMin > rhs.trendBytesPerMin }
                return lhs.totalRSS > rhs.totalRSS
            }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - History snapshot

    private func recordSnapshot(_ sample: SystemSample, assessment: RiskAssessment) {
        let snapshot = HistorySnapshot(
            id: 0,
            timestamp: sample.timestamp,
            risk: assessment.level.label,
            pressure: pressureLevel.label,
            memUsedBytes: sample.usedBytes,
            memTotalBytes: sample.physicalTotalBytes,
            swapUsedBytes: sample.swapUsedBytes,
            swapRateBytesPerMin: sample.swapRateBytesPerMin,
            cpuPercent: sample.cpuUsage * 100,
            top: latestGroups.prefix(5).map {
                HistorySnapshot.TopEntry(
                    name: $0.displayName,
                    rssBytes: $0.totalRSS,
                    cpuPercent: $0.cpuFraction * 100,
                    trendBytesPerMin: $0.trendBytesPerMin)
            },
            fastestGrowing: fastestGrowing?.name)
        let encoded = (try? JSONEncoder().encode(snapshot))
            .flatMap { String(data: $0, encoding: .utf8) }
        history.record(HistoryEvent(
            kind: "snapshot",
            summary: "风险 \(assessment.level.label) · 内存 \(fmtBytes(sample.usedBytes))"
                + "/\(fmtBytes(sample.physicalTotalBytes))"
                + " · Swap \(fmtBytes(sample.swapUsedBytes))",
            detail: encoded))
    }

    /// Post-mortem hook: if the previous session's last recorded snapshot was
    /// Danger/Critical, the machine likely just had a bad episode (or a hard
    /// lockup). Surface it immediately.
    private func checkPreviousSessionEnd() {
        guard let last = history.lastSnapshotBefore(Date()) else { return }
        let lastLevel = last.riskLevel
        guard lastLevel == .danger || lastLevel == .critical else { return }
        let summary = "上次会话以「\(lastLevel.label)」结束 — "
            + "内存 \(fmtBytes(last.memUsedBytes))/\(fmtBytes(last.memTotalBytes))，"
            + "Swap \(fmtBytes(last.swapUsedBytes))"
        history.record(HistoryEvent(kind: "riskChange", summary: summary))
        log.warning("Previous session ended at \(lastLevel.label, privacy: .public)")
        if settingsStore.settings.notificationsEnabled {
            Notifier.shared.notify(
                title: "内存守护 — 上次会话以「\(lastLevel.label)」结束",
                body: "最后记录：内存 \(fmtBytes(last.memUsedBytes)) / \(fmtBytes(last.memTotalBytes))，"
                    + "Swap \(fmtBytes(last.swapUsedBytes))。点击查看事件报告。",
                openIncident: true)
        }
    }

    // MARK: - Diagnostics

    private func diagnosticsLine(_ sample: SystemSample, assessment: RiskAssessment) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let top = latestGroups.prefix(3)
            .map { "\($0.displayName)=\(fmtBytes($0.totalRSS))" }
            .joined(separator: ", ")
            return String(
            format: "%@ pressure=%@ mem=%.1f/%.1fGB swap=%.2fGB rate=%@ pageout=%.0f/s decomp=%.0f/s cpu=%.1f%% risk=%.2f %@ top=[%@]",
            formatter.string(from: sample.timestamp),
            sample.pressure.label,
            Double(sample.usedBytes) / 1_073_741_824,
            Double(sample.physicalTotalBytes) / 1_073_741_824,
            Double(sample.swapUsedBytes) / 1_073_741_824,
            fmtRate(sample.swapRateBytesPerMin),
            sample.pageoutRate,
            sample.decompressionRate,
            sample.cpuUsage * 100,
            assessment.score,
            assessment.level.label,
            top)
    }
}
