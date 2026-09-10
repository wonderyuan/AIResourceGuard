import Foundation
import Darwin

/// A process identity that survives PID reuse: pid + the kernel's start
/// time for that pid. Any *delayed* signal (recovery SIGCONT minutes later,
/// last-resort SIGKILL after the grace period, ledger recovery after a
/// crash) must verify the identity first — otherwise it can hit an innocent
/// process that happened to recycle the pid.
struct ProcessIdentity: Equatable, Hashable, Codable {
    let pid: Int32
    /// Epoch seconds from proc_bsdinfo.pbi_start_tvsec.
    let startSeconds: TimeInterval
    let name: String

    init(pid: Int32, startSeconds: TimeInterval, name: String) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.name = name
    }

    /// Reads the identity the kernel currently associates with `pid`
    /// (nil when the pid is gone).
    static func current(for pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, 1 /* PROC_PIDTBSDINFO */, 0, &info,
                           Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0 else {
            return nil
        }
        let start = TimeInterval(info.pbi_start_tvsec)
        guard start > 0 else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let name = proc_name(pid, &nameBuffer, 1024) > 0
            ? String(cString: nameBuffer) : "pid \(pid)"
        return ProcessIdentity(pid: pid, startSeconds: start, name: name)
    }

    init?(record: ProcessRecord) {
        guard record.startSeconds > 0 else { return nil }
        self.pid = record.pid
        self.startSeconds = record.startSeconds
        self.name = record.name
    }

    /// True when this pid still refers to the same process instance.
    func stillCurrent() -> Bool {
        guard let now = ProcessIdentity.current(for: pid) else { return false }
        return now.startSeconds == startSeconds
    }

    /// pid alive but recycled to a different instance?
    var wasRecycled: Bool {
        guard let now = ProcessIdentity.current(for: pid) else { return false }
        return now.startSeconds != startSeconds
    }
}
