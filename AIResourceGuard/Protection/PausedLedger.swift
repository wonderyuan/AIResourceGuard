import Foundation
import Darwin
import os

private let log = Logger(subsystem: "local.dev.AIResourceGuard", category: "protection")

/// Durable record of tasks auto-paused by the guard. If the guard itself
/// dies (crash, force quit, machine lockup), tasks would stay SIGSTOPped
/// forever — so the ledger is persisted on every change and replayed
/// (resumed) on the next launch.
struct PausedLedgerEntry: Codable, Equatable {
    let groupKey: String
    let displayName: String
    let identities: [ProcessIdentity]
    /// Physical footprint at pause time, bytes (resume order: smallest first).
    let footprintBytes: UInt64
    let pausedAt: Date
    /// true = user paused manually (never auto-resumed).
    var isManual: Bool = false
}

enum PausedLedger {
    private static let key = "local.dev.AIResourceGuard.pausedLedger.v1"

    static func load() -> [PausedLedgerEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([PausedLedgerEntry].self, from: data) else {
            return []
        }
        return entries
    }

    static func save(_ entries: [PausedLedgerEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Resumes ledger tasks whose pid still belongs to the original
    /// process (PID-reuse safe). AUTO-paused tasks are resumed (the guard
    /// owes them a recovery); MANUAL pauses stay frozen — the user chose to
    /// pause them and that choice survives restarts.
    @discardableResult
    static func recoverOrphanedTasks(history: HistoryStore) -> Int {
        let entries = load()
        guard !entries.isEmpty else { return 0 }
        var resumed = 0
        var keptFrozen = 0
        for entry in entries {
            if entry.isManual {
                keptFrozen += 1
                continue // user paused this — keep it frozen
            }
            for identity in entry.identities {
                guard identity.stillCurrent() else { continue }
                if kill(identity.pid, SIGCONT) == 0 || errno == ESRCH {
                    resumed += 1
                }
            }
        }
        if resumed > 0 || keptFrozen > 0 {
            history.record(HistoryEvent(
                kind: "action",
                summary: "启动恢复：自动恢复 \(resumed) 个进程，保留 \(keptFrozen) 个手动暂停的任务",
                detail: entries.map(\.displayName).joined(separator: ", ")))
        }
        // Keep manual entries in the ledger; clear only auto ones.
        let manualEntries = entries.filter(\.isManual)
        save(manualEntries)
        log.info("Ledger recovery: resumed \(resumed), kept frozen \(keptFrozen)")
        return resumed
    }
}
