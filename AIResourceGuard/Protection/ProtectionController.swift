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
struct PausedTask {
    let groupKey: String
    let displayName: String
    let pids: [Int32]
    let rssBytes: UInt64
}

/// Executes pause/resume/terminate against process groups, after the policy
/// gate. Target selection uses RescueScorer (expected release × abnormality ×
/// impact, frontmost app protected). After Critical, paused tasks resume in
/// stages via RecoveryPlanner instead of all at once. Every user-visible
/// outcome is reported through `onFeedback` for the popover.
@MainActor
final class ProtectionController {
    /// Short human-readable outcome lines for the popover.
    var onFeedback: ((String) -> Void)?

    private let settingsProvider: () -> AppSettings
    private let policyProvider: () -> ProtectedProcessPolicy
    private unowned let history: HistoryStore

    private var pausedTasks: [PausedTask] = []
    private var recoveryStableSince: Date?
    private var recoveryNextResumeAt: Date?
    private var recoveryLastResumed: PausedTask?
    private var recoveryLastResumedAt: Date?
    private var allRecoveredAnnounced = false

    private var lastAutoPauseAt: Date?
    private var lastEmergencyAt: Date?
    private var criticalSince: Date?
    private var sigtermSentAt: [Int32: Date] = [:]

    init(settingsProvider: @escaping () -> AppSettings,
         policyProvider: @escaping () -> ProtectedProcessPolicy,
         history: HistoryStore) {
        self.settingsProvider = settingsProvider
        self.policyProvider = policyProvider
        self.history = history
    }

    // MARK: - Manual actions (Popover buttons)

    func pause(_ group: ProcessGroupInfo) {
        _ = act(group: group, action: .pause, isAutomatic: false)
    }

    func resume(_ group: ProcessGroupInfo) {
        _ = act(group: group, action: .resume, isAutomatic: false)
    }

    func terminate(_ group: ProcessGroupInfo) {
        _ = act(group: group, action: .terminate, isAutomatic: false)
    }

    func forceTerminate(_ group: ProcessGroupInfo) {
        _ = act(group: group, action: .forceTerminate, isAutomatic: false)
    }

    // MARK: - Automatic flow

    func handleAssessment(_ assessment: RiskAssessment,
                          groups: [ProcessGroupInfo],
                          context: ProtectionContext) {
        let settings = settingsProvider()
        let now = Date()
        let cooldown = settings.thresholds.notifyCooldownSeconds

        if assessment.level == .critical {
            if criticalSince == nil { criticalSince = now }

            // 1. Auto-pause the best rescue target among opted-in apps.
            if settings.autoProtectionEnabled,
               lastAutoPauseAt.map({ now.timeIntervalSince($0) >= min(90, cooldown) }) ?? true,
               let target = bestRescueTarget(in: groups, settings: settings, context: context) {
                let stopped = act(group: target, action: .pause, isAutomatic: true)
                if !stopped.isEmpty {
                    pausedTasks.append(PausedTask(
                        groupKey: target.key,
                        displayName: target.displayName,
                        pids: stopped,
                        rssBytes: target.totalRSS))
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
        } else {
            criticalSince = nil
        }

        // 3. Staged recovery whenever we hold paused tasks (any level).
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

    /// Safety net: resume everything before the app terminates so no task is
    /// left SIGSTOPped forever.
    func resumeAllForExit() {
        guard !pausedTasks.isEmpty else { return }
        for task in pausedTasks { resumePids(task.pids) }
        history.record(HistoryEvent(
            kind: "action",
            summary: "内存守护退出，已恢复全部 \(pausedTasks.count) 个已暂停任务",
            detail: nil))
        pausedTasks.removeAll()
    }

    // MARK: - Staged recovery

    private func runRecovery(assessment: RiskAssessment,
                             settings: AppSettings,
                             now: Date) {
        let decision = RecoveryPlanner.decide(
            RecoveryState(
                level: assessment.level,
                now: now,
                pausedTaskCount: pausedTasks.count,
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
            // Smallest task first — least likely to re-stress the machine.
            guard let index = pausedTasks.indices.min(by: {
                pausedTasks[$0].rssBytes < pausedTasks[$1].rssBytes
            }) else { return }
            let task = pausedTasks.remove(at: index)
            resumePids(task.pids)
            recoveryLastResumed = task
            recoveryLastResumedAt = now
            recoveryNextResumeAt = now.addingTimeInterval(settings.thresholds.recoveryObserveSeconds)
            history.record(HistoryEvent(
                kind: "action",
                summary: "分步恢复：已恢复 \(task.displayName)（剩余 \(pausedTasks.count) 个）",
                detail: "pids: \(task.pids)"))
            if pausedTasks.isEmpty {
                onFeedback?("已恢复任务：\(task.displayName)（全部恢复）")
            } else {
                onFeedback?("已恢复任务：\(task.displayName)（剩余 \(pausedTasks.count) 个）")
            }

        case .repauseLast:
            guard let task = recoveryLastResumed else { return }
            let stillAlive = task.pids.filter { kill($0, 0) == 0 }
            if !stillAlive.isEmpty {
                for pid in stillAlive { kill(pid, SIGSTOP) }
                pausedTasks.append(PausedTask(
                    groupKey: task.groupKey,
                    displayName: task.displayName,
                    pids: stillAlive,
                    rssBytes: task.rssBytes))
                history.record(HistoryEvent(
                    kind: "action",
                    summary: "恢复 \(task.displayName) 后系统再次承压，已重新暂停",
                    detail: "pids: \(stillAlive)"))
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
                    baselineMeanRSSMB: context.baseline.groupMeanRSSMB(displayName: group.displayName))
                return (group, score)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Helpers

    private func resumePids(_ pids: [Int32]) {
        for pid in pids where kill(pid, SIGCONT) != 0 && errno != ESRCH {
            // best effort
        }
    }

    /// After the grace period, pids that received an automatic SIGTERM and
    /// are still alive get SIGKILL as the documented last resort.
    private func enforceSigtermGrace(now: Date, settings: AppSettings) {
        guard !sigtermSentAt.isEmpty else { return }
        let grace = Double(settings.emergencyKillGraceSeconds)
        for (pid, sentAt) in sigtermSentAt where now.timeIntervalSince(sentAt) >= grace {
            sigtermSentAt[pid] = nil
            if kill(pid, 0) == 0 {
                if kill(pid, SIGKILL) == 0 {
                    history.record(HistoryEvent(
                        kind: "action",
                        summary: "最后手段：pid \(pid) 未响应 SIGTERM，已发送 SIGKILL",
                        detail: nil))
                    log.warning("Last-resort SIGKILL for pid \(pid)")
                }
            }
        }
    }

    // MARK: - Core

    @discardableResult
    private func act(group: ProcessGroupInfo, action: ProcessAction, isAutomatic: Bool) -> [Int32] {
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

        var stopped: [Int32] = []
        var denied: [String] = []
        var failed: [Int32] = []

        for proc in group.processes {
            if action == .pause && proc.isStopped { continue }
            if action == .resume && !proc.isStopped { continue }

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
                stopped.append(proc.pid)
                if isAutomatic && action == .terminate {
                    sigtermSentAt[proc.pid] = Date()
                }
            } else {
                failed.append(proc.pid)
            }
        }

        let mode = isAutomatic ? "自动" : "手动"
        if !stopped.isEmpty || !denied.isEmpty || !failed.isEmpty {
            let summary = "[\(mode)]\(verb(for: action)) \(group.displayName)："
                + "\(stopped.count) 个进程已发送 \(signalName)"
                + (denied.isEmpty ? "" : "，\(denied.count) 个被安全策略拦截")
                + (failed.isEmpty ? "" : "，\(failed.count) 个失败")
            let detail = ["sent: \(stopped)", "blocked: \(denied)",
                          "failed: \(failed)"].joined(separator: "\n")
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
        } else if !failed.isEmpty, !isAutomatic {
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
