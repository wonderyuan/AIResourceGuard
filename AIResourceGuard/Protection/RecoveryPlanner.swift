import Foundation

/// Pure decision core for staged recovery after auto-pause.
///
/// After Critical, paused tasks are NOT resumed all at once: the system must
/// stay 正常 for `recoveryWindowSeconds`, then tasks resume one at a time
/// (smallest first — least likely to re-stress the machine), with
/// `recoveryObserveSeconds` of stability required between resumes. If the
/// system degrades again while observing a just-resumed task, that task is
/// re-paused and the recovery window restarts.
enum RecoveryDecision: Equatable {
    case none
    case startWindow
    case resumeNext
    /// The task resumed last appears to have re-stressed the system.
    case repauseLast
    /// All paused tasks have been resumed (announce once, then idle).
    case announceAllRecovered
}

struct RecoveryState {
    var level: RiskLevel
    var now: Date
    var pausedTaskCount: Int
    var stableSince: Date?
    var nextResumeAt: Date?
    /// When the most recent single resume happened (nil once it survived
    /// its observation window).
    var lastResumedAt: Date?
    var justDeescalatedFromDanger: Bool
}

enum RecoveryPlanner {
    static func decide(_ state: RecoveryState,
                       windowSeconds: Double,
                       observeSeconds: Double) -> RecoveryDecision {
        // Degradation while still observing a fresh resume → take it back.
        if state.level >= .warning {
            if let resumedAt = state.lastResumedAt,
               state.now.timeIntervalSince(resumedAt) < observeSeconds {
                return .repauseLast
            }
            return .none
        }

        if state.level != .normal { return .none }

        if state.pausedTaskCount == 0 {
            // The final resumed task still needs to survive its observation
            // window before we declare full recovery.
            if let resumedAt = state.lastResumedAt {
                if state.now.timeIntervalSince(resumedAt) >= observeSeconds {
                    return .announceAllRecovered
                }
                return .none
            }
            if state.justDeescalatedFromDanger { return .announceAllRecovered }
            return .none
        }

        guard let stableSince = state.stableSince else { return .startWindow }
        guard state.now.timeIntervalSince(stableSince) >= windowSeconds else { return .none }
        if let nextAt = state.nextResumeAt, state.now < nextAt { return .none }
        return .resumeNext
    }
}
