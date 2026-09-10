import Foundation
import Combine
import AppKit
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
    /// Curated "值得关注的应用" — attribution-driven, never empty at Danger+.
    @Published private(set) var notableApps: [ProcessGroupInfo] = []
    /// Why the notable list looks the way it does (fallback note, coverage,
    /// pressure classification) — for the popover.
    @Published private(set) var notableContext = NotableSelection()
    @Published private(set) var assessment = RiskAssessment.initial
    @Published private(set) var pressureLevel: PressureLevel = .normal
    @Published private(set) var actionFeedback: [ActionFeedback] = []
    /// Latest scan attribution confidence (for 设置 ▸ 关于).
    @Published private(set) var scanStats: ScanStats?
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
    /// Machine-relative learned normal, bootstrapped from history.
    private let baseline = BaselineTracker()
    /// Group key of the app the user is currently interacting with.
    private var foregroundGroupKey: String?
    private var terminateObserver: NSObjectProtocol?

    private var started = false
    private var latestGroups: [ProcessGroupInfo] = []
    private var fastestGrowing: (name: String, bytesPerMin: Double)?
    private var lastSnapshotAt: Date?
    private var lastHiddenPublishAt = Date.distantPast
    private var latestScanStats: ScanStats?
    /// When the last process scan delivered (governance freshness gate).
    private var lastScanAt: Date?
    /// A governance decision is waiting for a fresh scan to arrive.
    private var pendingGovernance = false
    /// After a serious episode ends, the system behaves atypically for a
    /// while — don't learn "normal" from it.
    private var baselineQuarantineUntil: Date?

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

        // Seed the baseline from persisted history so it is useful at once.
        baseline.bootstrap(from: history.snapshotsSync(hours: 24))

        // Resume tasks left frozen by a previous crashed session.
        protection.recoverOrphanedTasks()

        // Safety net: never leave auto-paused tasks SIGSTOPped behind us.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.protection.resumeAllForExit()
        }

        if notifications { Notifier.shared.requestIfNeeded() }
        checkPreviousSessionEnd()
    }

    /// Whether the machine-relative baseline has enough samples to be used.
    var baselineReady: Bool { baseline.swapUsedMB.isReady }

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
        updateForeground()

        var input = RiskInput(
            timestamp: sample.timestamp,
            pressure: pressureLevel,
            memoryUsedFraction: sample.usedFraction,
            swapUsedBytes: sample.swapUsedBytes,
            swapRateBytesPerMin: sample.swapRateBytesPerMin,
            pageoutRate: sample.pageoutRate,
            decompressionRate: sample.decompressionRate,
            topGrowthBytesPerMin: fastestGrowing?.bytesPerMin ?? 0,
            topGrowthGroup: fastestGrowing?.name)
        input.baseline = baseline.context(sample: sample, groups: latestGroups)

        let result = riskEngine.evaluate(input)
        assessment = result

        // Learn "normal" only while truly stable: level 正常 and outside the
        // post-incident quarantine window (recovery behavior is atypical).
        if result.justDeescalated, result.previousLevel >= .danger {
            baselineQuarantineUntil = Date().addingTimeInterval(600)
        }
        let quarantined = baselineQuarantineUntil.map { Date() < $0 } ?? false
        if result.level == .normal, !quarantined {
            baseline.recordNormalSystem(sample: sample)
        }

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

        // Recovery bookkeeping runs on every tick and needs no group data.
        protection.handleRecovery(result)

        // Governance (auto-pause / emergency terminate) only acts on FRESH
        // process data: at Danger/Critical, force a re-scan first and decide
        // when it arrives — never act on a stale process list.
        let governanceArmed = settingsStore.settings.autoProtectionEnabled
            || settingsStore.settings.emergencyKillEnabled
        if result.level >= .danger && governanceArmed {
            let scanAge = lastScanAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if scanAge > 2.0 {
                pendingGovernance = true
                processMonitor.scanNow()
            } else {
                protection.govern(
                    result,
                    groups: latestGroups,
                    context: ProtectionContext(
                        foregroundGroupKey: foregroundGroupKey,
                        baseline: baseline))
                pendingGovernance = false
            }
        } else {
            pendingGovernance = false
        }

        // Level changes re-curate the notable list between scans.
        if result.level != result.previousLevel {
            recomputeNotable()
        }

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
        latestScanStats = output.stats
        lastScanAt = Date()

        // A governance decision was deferred until fresh data arrived.
        if pendingGovernance, assessment.level >= .danger {
            pendingGovernance = false
            protection.govern(
                assessment,
                groups: output.groups,
                context: ProtectionContext(
                    foregroundGroupKey: foregroundGroupKey,
                    baseline: baseline))
        }

        let quarantined = baselineQuarantineUntil.map { Date() < $0 } ?? false
        if assessment.level == .normal, !quarantined {
            baseline.recordNormalGroups(output.groups)
        }

        recomputeNotable()

        // Skip expensive UI publishes while the popover is closed.
        if popoverVisible || Date().timeIntervalSince(lastHiddenPublishAt) > 15 {
            groups = output.groups
            notableApps = notableContext.apps
            scanStats = latestScanStats
            lastHiddenPublishAt = Date()
        }
    }

    /// Attribution-driven curation of "值得关注的应用". Recomputed on every
    /// scan *and* every risk-level change — at Danger/Critical the result is
    /// never an empty list (falls back to biggest visible consumers).
    private func recomputeNotable() {
        let selection = AttributionEngine.analyze(
            level: assessment.level,
            sample: system,
            groups: latestGroups,
            baseline: baseline,
            scanStats: latestScanStats)
        notableContext = selection
        if popoverVisible {
            notableApps = selection.apps
        }
    }

    /// Tracks which app the user is actively using — the rescue scorer
    /// protects it from auto-pause.
    private func updateForeground() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let path = app.bundleURL?.path,
              let bundle = ProcessTreeAggregator.appBundleName(path: path) else {
            return
        }
        foregroundGroupKey = ProcessTreeAggregator.appGroup(forBundle: bundle).key
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
                    trendBytesPerMin: $0.footprintTrendBytesPerMin,
                    footprintBytes: $0.totalFootprint,
                    groupKey: $0.key)
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
        let stale = latestGroups
            .filter(\.isStaleWorkload)
            .map { "\($0.displayName)(\(fmtBytes($0.totalRSS)),age \(Int($0.ageSeconds / 60))m)" }
            .joined(separator: ", ")
        return String(
            format: "%@ pressure=%@ mem=%.1f/%.1fGB swap=%.2fGB rate=%@ pageout=%.0f/s decomp=%.0f/s cpu=%.1f%% risk=%.2f %@ base=%@ top=[%@] stale=[%@]",
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
            baseline.swapUsedMB.isReady
                ? String(format: "swap%.0fMB±%.0f", baseline.swapUsedMB.mean, baseline.swapUsedMB.stddev)
                : "learning(\(baseline.swapUsedMB.count))",
            top,
            stale)
    }
}
