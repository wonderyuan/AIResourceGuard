import Foundation
import Darwin
import os

private let log = Logger(subsystem: "local.dev.AIResourceGuard", category: "protection")

/// Executes pause/resume/terminate against process groups, after the policy
/// gate. Runs the automatic-protection flow: at Critical (opt-in) auto-pause
/// managed apps; if Emergency Kill is on and Critical persists, SIGTERM the
/// approved groups, then SIGKILL only after a grace period as the last resort.
@MainActor
final class ProtectionController {
    private let settingsProvider: () -> AppSettings
    private let policyProvider: () -> ProtectedProcessPolicy
    private unowned let history: HistoryStore

    private var autoPausedPids: Set<Int32> = []
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
        act(group: group, action: .pause, isAutomatic: false)
    }

    func resume(_ group: ProcessGroupInfo) {
        act(group: group, action: .resume, isAutomatic: false)
    }

    func terminate(_ group: ProcessGroupInfo) {
        act(group: group, action: .terminate, isAutomatic: false)
    }

    func forceTerminate(_ group: ProcessGroupInfo) {
        act(group: group, action: .forceTerminate, isAutomatic: false)
    }

    // MARK: - Automatic flow

    func handleAssessment(_ assessment: RiskAssessment, groups: [ProcessGroupInfo]) {
        let settings = settingsProvider()
        let now = Date()
        let cooldown = settings.thresholds.notifyCooldownSeconds

        if assessment.level == .critical {
            if criticalSince == nil { criticalSince = now }

            // 1. Auto-pause opted-in managed apps.
            if settings.autoProtectionEnabled,
               lastAutoPauseAt.map({ now.timeIntervalSince($0) >= min(90, cooldown) }) ?? true,
               let target = autoPauseTarget(in: groups, settings: settings) {
                act(group: target, action: .pause, isAutomatic: true)
                lastAutoPauseAt = now
            }

            // 2. Emergency terminate after sustained Critical.
            if settings.emergencyKillEnabled,
               let since = criticalSince,
               now.timeIntervalSince(since) >= Double(settings.emergencyKillDelaySeconds),
               lastEmergencyAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true,
               let target = emergencyTarget(in: groups, settings: settings) {
                act(group: target, action: .terminate, isAutomatic: true)
                lastEmergencyAt = now
            }
        } else {
            criticalSince = nil
            if assessment.level == .normal, settings.autoResumeOnNormal, !autoPausedPids.isEmpty {
                resumeAutoPaused()
            }
        }

        enforceSigtermGrace(now: now, settings: settings)
    }

    /// Auto-pauses the heaviest opted-in managed group that is still running.
    private func autoPauseTarget(in groups: [ProcessGroupInfo], settings: AppSettings) -> ProcessGroupInfo? {
        groups.first { group in
            guard let managed = settings.managedApps.first(where: { $0.key == group.key }),
                  managed.allowAutoPause else { return false }
            return group.processes.contains { !$0.isStopped }
        }
    }

    private func emergencyTarget(in groups: [ProcessGroupInfo], settings: AppSettings) -> ProcessGroupInfo? {
        groups.first { group in
            guard let managed = settings.managedApps.first(where: { $0.key == group.key }),
                  managed.allowEmergencyTerminate else { return false }
            return group.processes.contains { !$0.isStopped }
        }
    }

    private func resumeAutoPaused() {
        let pids = autoPausedPids
        autoPausedPids = []
        guard !pids.isEmpty else { return }
        var resumed: [Int32] = []
        for pid in pids where kill(pid, SIGCONT) == 0 || errno == ESRCH {
            resumed.append(pid)
        }
        history.record(HistoryEvent(
            kind: "action",
            summary: "Auto-resumed \(resumed.count) process(es) after recovery",
            detail: "\(resumed)"))
        log.info("Auto-resumed \(resumed.count) pids")
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
                        summary: "Last-resort SIGKILL pid \(pid) (ignored SIGTERM)",
                        detail: nil))
                    log.warning("Last-resort SIGKILL for pid \(pid)")
                }
            }
        }
    }

    // MARK: - Core

    private func act(group: ProcessGroupInfo, action: ProcessAction, isAutomatic: Bool) {
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
                if isAutomatic && action == .pause {
                    autoPausedPids.insert(proc.pid)
                }
                if isAutomatic && action == .terminate {
                    sigtermSentAt[proc.pid] = Date()
                }
            } else {
                failed.append(proc.pid)
            }
        }

        let mode = isAutomatic ? "auto" : "manual"
        if !stopped.isEmpty || !denied.isEmpty || !failed.isEmpty {
            let summary = "\(mode.capitalized) \(verb(for: action)) \(group.displayName): "
                + "\(stopped.count) sent \(signalName)"
                + (denied.isEmpty ? "" : ", \(denied.count) blocked")
                + (failed.isEmpty ? "" : ", \(failed.count) failed")
            let detail = ["sent: \(stopped)", "blocked: \(denied)",
                          "failed: \(failed)"].joined(separator: "\n")
            history.record(HistoryEvent(kind: "action", summary: summary, detail: detail))
            log.info("\(summary, privacy: .public)")
        }
    }

    private func verb(for action: ProcessAction) -> String {
        switch action {
        case .pause: return "pause"
        case .resume: return "resume"
        case .terminate: return "terminate"
        case .forceTerminate: return "force-terminate"
        }
    }
}
