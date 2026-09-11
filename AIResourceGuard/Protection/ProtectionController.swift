import Foundation
import Darwin
import os

private let log = Logger(subsystem: "local.dev.AIResourceGuard", category: "protection")

/// Per-evaluation context the controller needs beyond groups + settings.
struct ProtectionContext {
    /// Group key of the app the user is currently looking at (frontmost).
    var foregroundGroupKey: String?
    var baseline: BaselineTracker
}

/// One task paused by auto-protection, tracked for staged recovery.
/// PIDs are stored as identities (pid + kernel start time) so delayed
/// SIGCONT can never hit a recycled pid.
struct PausedTask {
    let groupKey: String
    let displayName: String
    let identities: [ProcessIdentity]
    /// Physical footprint at pause time; staged recovery resumes smallest first.
    let footprintBytes: UInt64
    let pausedAt: Date
    /// true = user clicked pause (NEVER auto-resumed);
    /// false = auto-protection paused it (staged recovery may resume).
    let isManual: Bool

    var ledgerEntry: PausedLedgerEntry {
        PausedLedgerEntry(groupKey: groupKey, displayName: displayName,
                          identities: identities, footprintBytes: footprintBytes,
                          pausedAt: pausedAt, isManual: isManual)
    }
}

/// Executes pause/resume/terminate against process groups, after the policy
/// gate. Two separate paths:
///
/// - `handleRecovery` runs on every tick (cheap, no group data needed);
/// - `govern` runs only on FRESH scan results — MonitorCenter forces a
///   re-scan at Danger/Critical before any auto-pause/terminate decision,
///   so actions never target stale process lists.
///
/// Delayed signals (staged-resume SIGCONT, last-resort SIGKILL) always
/// verify ProcessIdentity first. Paused tasks are persisted in
/// AutoPausedLedger so a guard crash cannot leave tasks frozen forever.
@MainActor
final class ProtectionController {
    /// Short human-readable outcome lines for the popover.
    var onFeedback: ((String) -> Void)?
    /// Notifies MonitorCenter whenever the paused task list changes.
    var onPausedTasksChanged: (([PausedTask]) -> Void)?

    private let settingsProvider: () -> AppSettings
    private let policyProvider: () -> ProtectedProcessPolicy
    private unowned let history: HistoryStore

    private var pausedTasks: [PausedTask] = [] {
        didSet {
            persistLedger()
            onPausedTasksChanged?(pausedTasks)
        }
    }
    private var recoveryStableSince: Date?
    private var recoveryNextResumeAt: Date?
    private var recoveryLastResumed: PausedTask?
    private var recoveryLastResumedAt: Date?
    private var allRecoveredAnnounced = false

    private var lastAutoPauseAt: Date?
    private var lastEmergencyAt: Date?
    private var criticalSince: Date?
    /// Automatic SIGTERM sent, awaiting the grace period (identity-keyed so
    /// the last-resort SIGKILL can never hit a recycled pid).
    private var sigtermLedger: [ProcessIdentity: Date] = [:]

    init(settingsProvider: @escaping () -> AppSettings,
         policyProvider: @escaping () -> ProtectedProcessPolicy,
         history: HistoryStore) {
        self.settingsProvider = settingsProvider
        self.policyProvider = policyProvider
        self.history = history
    }

    // MARK: - Startup / shutdown safety

    /// Resumes tasks left frozen by a previous crashed session.
    func recoverOrphanedTasks() {
        PausedLedger.recoverOrphanedTasks(history: history)
    }

    /// Resume a specific paused task by its ledger entry (used by the
    /// "已暂停的任务" section which is ledger-driven, not scan-driven).
    func resumePausedTask(_ task: PausedTask) {
        log.info("Ledger resume: \(task.displayName, privacy: .public)")
        resumeIdentities(task.identities)
        pausedTasks.removeAll { $0.groupKey == task.groupKey }
        onFeedback?("已恢复 \(task.displayName) 任务")
    }

    /// Safety net: resume everything before the app terminates gracefully.
    func resumeAllForExit() {
        guard !pausedTasks.isEmpty else { return }
        for task in pausedTasks { resumeIdentities(task.identities) }
        history.record(HistoryEvent(
            kind: "action",
            summary: "内存守护退出，已恢复全部 \(pausedTasks.count) 个已暂停任务",
            detail: nil))
        pausedTasks.removeAll()
        PausedLedger.clear()
    }

    // MARK: - Manual actions (Popover buttons)

    func pause(_ group: ProcessGroupInfo) {
        log.info("Manual pause requested for \(group.displayName, privacy: .public) (\(group.processes.count) procs)")
        let stopped = act(group: group, action: .pause, isAutomatic: false)
        log.info("Manual pause result: \(stopped.count) signaled, \(stopped.map(\.pid), privacy: .public)")
    }

    func resume(_ group: ProcessGroupInfo) {
        log.info("Manual resume requested for \(group.displayName, privacy: .public)")
        _ = act(group: group, action: .resume, isAutomatic: false)
    }

    func terminate(_ group: ProcessGroupInfo) {
        log.info("Manual terminate requested for \(group.displayName, privacy: .public)")
        _ = act(group: group, action: .terminate, isAutomatic: false)
    }

    func forceTerminate(_ group: ProcessGroupInfo) {
        log.info("Manual force-terminate requested for \(group.displayName, privacy: .public)")
        _ = act(group: group, action: .forceTerminate, isAutomatic: false)
    }

    // MARK: - Automatic governance (FRESH scan data only)

    /// Caller contract: `groups` comes from a scan that just completed
    /// (MonitorCenter enforces this by re-scanning at Danger/Critical).
    func govern(_ assessment: RiskAssessment,
                groups: [ProcessGroupInfo],
                context: ProtectionContext) {
        guard assessment.level == .critical else { return }
        let settings = settingsProvider()
        let now = Date()
        let cooldown = settings.thresholds.notifyCooldownSeconds
        if criticalSince == nil { criticalSince = now }

        // 1. Auto-pause the best rescue target among opted-in apps.
        if settings.autoProtectionEnabled,
           lastAutoPauseAt.map({ now.timeIntervalSince($0) >= min(90, cooldown) }) ?? true,
           let target = bestRescueTarget(in: groups, settings: settings, context: context) {
            let stoppedIdentities = act(group: target, action: .pause, isAutomatic: true)
            if !stoppedIdentities.isEmpty {
                pausedTasks.append(PausedTask(
                    groupKey: target.key,
                    displayName: target.displayName,
                    identities: stoppedIdentities,
                    footprintBytes: target.totalFootprint,
                    pausedAt: now,
                    isManual: false))
                recoveryStableSince = nil
                allRecoveredAnnounced = false
            }
            lastAutoPauseAt = now
        }

        // 2. Emergency terminate after sustained Critical.
        if settings.emergencyKillEnabled,
           let since = criticalSince,
           now.timeIntervalSince(since) >= Double(settings.emergencyKillDelaySeconds),
           lastEmergencyAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true,
           let target = bestRescueTarget(in: groups, settings: settings, context: context) {
            _ = act(group: target, action: .terminate, isAutomatic: true)
            lastEmergencyAt = now
        }

        enforceSigtermGrace(now: now, settings: settings)
    }

    // MARK: - Recovery (every tick, no group data needed)

    func handleRecovery(_ assessment: RiskAssessment) {
        let settings = settingsProvider()
        let now = Date()

        if assessment.level != .critical {
            criticalSince = nil
        }

        if !pausedTasks.isEmpty || recoveryLastResumed != nil {
            runRecovery(assessment: assessment, settings: settings, now: now)
        } else if assessment.level == .normal,
                  assessment.justDeescalated, assessment.previousLevel >= .danger,
                  !allRecoveredAnnounced {
            onFeedback?("系统压力已恢复")
            allRecoveredAnnounced = true
        }

        enforceSigtermGrace(now: now, settings: settings)
    }

    // MARK: - Staged recovery

    private func runRecovery(assessment: RiskAssessment,
                             settings: AppSettings,
                             now: Date) {
        let autoPausedCount = pausedTasks.filter { !$0.isManual }.count
        let decision = RecoveryPlanner.decide(
            RecoveryState(
                level: assessment.level,
                now: now,
                pausedTaskCount: autoPausedCount,
                stableSince: recoveryStableSince,
                nextResumeAt: recoveryNextResumeAt,
                lastResumedAt: recoveryLastResumedAt,
                justDeescalatedFromDanger: assessment.justDeescalated
                    && assessment.previousLevel >= .danger),
            windowSeconds: settings.thresholds.recoveryWindowSeconds,
            observeSeconds: settings.thresholds.recoveryObserveSeconds)

        switch decision {
        case .none:
            break

        case .startWindow:
            recoveryStableSince = now
            onFeedback?("系统压力回落，观察 \(Int(settings.thresholds.recoveryWindowSeconds)) 秒后开始逐步恢复任务")

        case .resumeNext:
            // Only auto-paused tasks are eligible for staged recovery.
            // Manually paused tasks stay frozen until the user resumes them.
            let autoTasks = pausedTasks.filter { !$0.isManual }
            guard let index = autoTasks.indices.min(by: {
                autoTasks[$0].footprintBytes < autoTasks[$1].footprintBytes
            }) else { return }
            let task = autoTasks[index]
            guard let taskIndex = pausedTasks.firstIndex(where: { $0.groupKey == task.groupKey }) else { return }
            pausedTasks.remove(at: taskIndex)
            resumeIdentities(task.identities)
            recoveryLastResumed = task
            recoveryLastResumedAt = now
            recoveryNextResumeAt = now.addingTimeInterval(settings.thresholds.recoveryObserveSeconds)
            history.record(HistoryEvent(
                kind: "action",
                summary: "分步恢复：已恢复 \(task.displayName)（剩余 \(pausedTasks.count) 个）",
                detail: "pids: \(task.identities.map(\.pid))"))
            if pausedTasks.isEmpty {
                onFeedback?("已恢复任务：\(task.displayName)（全部恢复）")
            } else {
                onFeedback?("已恢复任务：\(task.displayName)（剩余 \(pausedTasks.count) 个）")
            }

        case .repauseLast:
            guard let task = recoveryLastResumed else { return }
            let stillLive = task.identities.filter { $0.stillCurrent() }
            if !stillLive.isEmpty {
                for identity in stillLive { kill(identity.pid, SIGSTOP) }
                pausedTasks.append(PausedTask(
                    groupKey: task.groupKey,
                    displayName: task.displayName,
                    identities: stillLive,
                    footprintBytes: task.footprintBytes,
                    pausedAt: now,
                    isManual: task.isManual))
                history.record(HistoryEvent(
                    kind: "action",
                    summary: "恢复 \(task.displayName) 后系统再次承压，已重新暂停",
                    detail: "pids: \(stillLive.map(\.pid))"))
                onFeedback?("恢复 \(task.displayName) 后系统再次承压，已重新暂停并延长观察")
            }
            recoveryLastResumed = nil
            recoveryLastResumedAt = nil
            recoveryStableSince = now // restart the stability window
            recoveryNextResumeAt = nil

        case .announceAllRecovered:
            onFeedback?("系统压力已恢复，全部任务已恢复")
            allRecoveredAnnounced = true
            recoveryLastResumed = nil
            recoveryLastResumedAt = nil
            recoveryStableSince = nil
            recoveryNextResumeAt = nil
        }
    }

    // MARK: - Rescue targeting

    /// The best auto-pause candidate: opted-in, running, highest rescue score.
    private func bestRescueTarget(in groups: [ProcessGroupInfo],
                                  settings: AppSettings,
                                  context: ProtectionContext) -> ProcessGroupInfo? {
        let candidates = groups.filter { group in
            guard let managed = settings.managedApps.first(where: { $0.key == group.key }),
                  managed.allowAutoPause else { return false }
            return group.processes.contains { !$0.isStopped }
        }
        return candidates
            .map { group -> (ProcessGroupInfo, Double) in
                let score = RescueScorer.score(
                    group: group,
                    isForeground: group.key == context.foregroundGroupKey,
                    baselineMeanFootprintMB: context.baseline.groupMeanFootprintMB(groupKey: group.key))
                return (group, score)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Helpers

    private func persistLedger() {
        PausedLedger.save(pausedTasks.map(\.ledgerEntry))
    }

    /// SIGCONT only for pids that still belong to the original processes.
    private func resumeIdentities(_ identities: [ProcessIdentity]) {
        for identity in identities {
            guard identity.stillCurrent() else { continue }
            kill(identity.pid, SIGCONT)
        }
    }

    /// After the grace period, processes that received an automatic SIGTERM
    /// and are still the SAME process instance get SIGKILL as the documented
    /// last resort. Recycled pids are never killed.
    private func enforceSigtermGrace(now: Date, settings: AppSettings) {
        guard !sigtermLedger.isEmpty else { return }
        let grace = Double(settings.emergencyKillGraceSeconds)
        for (identity, sentAt) in sigtermLedger where now.timeIntervalSince(sentAt) >= grace {
            sigtermLedger[identity] = nil
            guard identity.stillCurrent() else {
                if identity.wasRecycled {
                    log.warning("Skipping last-resort SIGKILL: pid \(identity.pid) was recycled")
                }
                continue
            }
            if kill(identity.pid, SIGKILL) == 0 {
                history.record(HistoryEvent(
                    kind: "action",
                    summary: "最后手段：\(identity.name)（pid \(identity.pid)）未响应 SIGTERM，已发送 SIGKILL",
                    detail: nil))
                log.warning("Last-resort SIGKILL for pid \(identity.pid)")
            }
        }
    }

    // MARK: - Core

    /// Sends `signal` to every eligible member of the group, after the
    /// policy gate. Returns the identities that were actually signaled.
    @discardableResult
    private func act(group: ProcessGroupInfo, action: ProcessAction, isAutomatic: Bool)
        -> [ProcessIdentity] {
        let settings = settingsProvider()
        let policy = policyProvider()
        let selfPath = Bundle.main.bundleURL.path

        let signalName: String
        let signal: Int32
        switch action {
        case .pause: signal = SIGSTOP; signalName = "SIGSTOP"
        case .resume: signal = SIGCONT; signalName = "SIGCONT"
        case .terminate: signal = SIGTERM; signalName = "SIGTERM"
        case .forceTerminate: signal = SIGKILL; signalName = "SIGKILL"
        }

        var stopped: [ProcessIdentity] = []
        var denied: [String] = []
        var failed = 0

        for proc in group.processes {
            if action == .pause && proc.isStopped { continue }
            if action == .resume && !proc.isStopped { continue }
            // Delayed manual resume also verifies identity where available.
            if action == .resume, proc.startSeconds > 0,
               let identity = ProcessIdentity(record: proc), !identity.stillCurrent() {
                continue
            }

            let decision = policy.validate(
                pid: proc.pid,
                name: proc.name,
                path: proc.path,
                euid: proc.euid,
                groupKey: group.key,
                action: action,
                isAutomatic: isAutomatic,
                settings: settings,
                selfPath: selfPath)
            guard decision.allowed else {
                denied.append(decision.reason ?? "blocked by policy")
                continue
            }

            if kill(proc.pid, signal) == 0 {
                if proc.startSeconds > 0, let identity = ProcessIdentity(record: proc) {
                    stopped.append(identity)
                    if isAutomatic && action == .terminate {
                        sigtermLedger[identity] = Date()
                    }
                } else {
                    stopped.append(ProcessIdentity(
                        pid: proc.pid, startSeconds: 0, name: proc.name))
                }
            } else {
                failed += 1
            }
        }

        let mode = isAutomatic ? "自动" : "手动"
        if !stopped.isEmpty || !denied.isEmpty || failed > 0 {
            let summary = "[\(mode)]\(verb(for: action)) \(group.displayName)："
                + "\(stopped.count) 个进程已发送 \(signalName)"
                + (denied.isEmpty ? "" : "，\(denied.count) 个被安全策略拦截")
                + (failed == 0 ? "" : "，\(failed) 个失败")
            let detail = ["sent: \(stopped.map(\.pid))", "blocked: \(denied)"]
                .joined(separator: "\n")
            history.record(HistoryEvent(kind: "action", summary: summary, detail: detail))
            log.info("\(summary, privacy: .public)")
        }

        // Popover feedback — keep it to one clean sentence per action.
        if !stopped.isEmpty {
            switch action {
            case .pause:
                onFeedback?("已暂停 \(group.displayName) 任务"
                    + (isAutomatic ? "（自动保护）" : ""))
            case .resume:
                onFeedback?("已恢复 \(group.displayName) 任务")
            case .terminate:
                onFeedback?("已请求终止 \(group.displayName) 任务")
            case .forceTerminate:
                onFeedback?("已强制退出 \(group.displayName) 任务")
            }
        } else if !denied.isEmpty, !isAutomatic {
            onFeedback?("已拦截对 \(group.displayName) 的操作：\(denied[0])")
        } else if failed > 0, !isAutomatic {
            onFeedback?("操作失败（无权限或进程已退出）")
        }

        return stopped
    }

    private func verb(for action: ProcessAction) -> String {
        switch action {
        case .pause: return "暂停"
        case .resume: return "恢复"
        case .terminate: return "终止"
        case .forceTerminate: return "强制退出"
        }
    }
}
