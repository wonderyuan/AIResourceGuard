import Foundation
import Darwin

/// Low-frequency process scan using public libproc APIs:
/// `proc_listallpids`, `proc_pid_rusage` (RUSAGE_INFO_4), `proc_pidpath`,
/// `proc_pidinfo` (PROC_PIDTBSDINFO). CPU is a delta of rusage times between
/// scans; per-group RSS keeps a ~5-minute ring for growth trends.
/// `node`/`bun`/`deno` argv is read via the public `KERN_PROCARGS2` sysctl
/// (same mechanism ps(1) uses) to tag MCP servers.
///
/// After the per-process pass, name-based groups are adopted by their
/// ancestor app: ZCode → node/MCP/shell, IntelliJ → java/Gradle, 终端 → CLI
/// tools. Detached daemons (reparented to launchd) keep their own group.
final class ProcessMonitor {
    struct Output {
        let groups: [ProcessGroupInfo]
        let fastestGrowing: (name: String, bytesPerMin: Double)?
        /// Attribution confidence for this scan.
        let stats: ScanStats
    }

    var onScan: ((Output) -> Void)?

    private let queue = DispatchQueue(label: "local.dev.AIResourceGuard.process", qos: .utility)
    private var generation = 0
    private var interval: TimeInterval = 20
    private var isRunning = false

    private var lastScanAt: Date?
    private var lastCPUTimes: [Int32: (user: UInt64, system: UInt64)] = [:]
    private var groupTrendRings: [String: [(t: Date, rss: UInt64, footprint: UInt64)]] = [:]
    private var mcpFlags: [Int32: Bool] = [:]

    // Public C-macro constants that Swift cannot import from <libproc.h>/<sys/proc.h>.
    private let kRUSAGE_INFO_4: Int32 = 4
    private let kPROC_PIDTBSDINFO: Int32 = 1
    private let kSSTOP: UInt32 = 4
    private let kSZOMB: UInt32 = 5
    private let kCTL_KERN: Int32 = 1
    private let kKERN_PROCARGS2: Int32 = 38

    // MARK: - Lifecycle

    func start(interval: TimeInterval) {
        self.interval = interval
        guard !isRunning else { return }
        isRunning = true
        queue.async { [weak self] in self?.scanOnce() } // first scan immediately
        scheduleNext()
    }

    func stop() {
        isRunning = false
        generation += 1
    }

    func setInterval(_ newInterval: TimeInterval) {
        interval = newInterval
    }

    func scanNow() {
        queue.async { [weak self] in self?.scanOnce() }
    }

    private func scheduleNext() {
        generation += 1
        let g = generation
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.isRunning, self.generation == g else { return }
            self.scanOnce()
            self.scheduleNext()
        }
    }

    // MARK: - Scan

    private func scanOnce() {
        let now = Date()
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity)
        guard count > 0 else { return }

        let wall = max(now.timeIntervalSince(lastScanAt ?? now), 0.5)
        lastScanAt = now

        var records: [ProcessRecord] = []
        records.reserveCapacity(Int(count))
        var cpuTimes: [Int32: (user: UInt64, system: UInt64)] = [:]
        var ppidByPid: [Int32: Int32] = [:]
        var pathByPid: [Int32: String] = [:]
        var seenPids = Set<Int32>()
        var rusageReads = 0

        for pid in pids[0..<Int(count)] where pid > 0 && seenPids.insert(pid).inserted {
            var bsdInfo = proc_bsdinfo()
            guard proc_pidinfo(pid, kPROC_PIDTBSDINFO, 0, &bsdInfo,
                               Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0 else { continue }
            guard bsdInfo.pbi_status != kSZOMB else { continue }

            var rusage = rusage_info_v4()
            let rusageOK = withUnsafeMutablePointer(to: &rusage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, kRUSAGE_INFO_4, $0) == 0
                }
            }
            guard rusageOK else { continue }
            rusageReads += 1

            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let pathLength = proc_pidpath(pid, &pathBuffer, 4096)
            var path = pathLength > 0 ? String(cString: pathBuffer) : ""
            var name = path.isEmpty ? "" : (path as NSString).lastPathComponent
            if name.isEmpty {
                var nameBuffer = [CChar](repeating: 0, count: 1024)
                if proc_name(pid, &nameBuffer, 1024) > 0 {
                    name = String(cString: nameBuffer)
                } else {
                    name = "pid \(pid)"
                    path = ""
                }
            }

            ppidByPid[pid] = Int32(bitPattern: bsdInfo.pbi_ppid)
            pathByPid[pid] = path

            // CPU fraction of one core from rusage time deltas.
            let userTime = rusage.ri_user_time, systemTime = rusage.ri_system_time
            var cpuFraction = 0.0
            if let previous = lastCPUTimes[pid] {
                let elapsed = Double((userTime &- previous.user) + (systemTime &- previous.system))
                cpuFraction = min(32.0, elapsed / 1e9 / wall)
            }
            cpuTimes[pid] = (userTime, systemTime)

            // MCP detection for JS runtimes (cached per pid).
            var isMCP = false
            if name == "node" || name == "bun" || name == "deno" {
                if let cached = mcpFlags[pid] {
                    isMCP = cached
                } else {
                    isMCP = (readArguments(pid: pid) ?? []).contains {
                        $0.lowercased().contains("mcp")
                    }
                    mcpFlags[pid] = isMCP
                }
            }

            let (key, display, _) = ProcessTreeAggregator.classify(name: name, path: path)
            records.append(ProcessRecord(
                pid: pid,
                ppid: Int32(bitPattern: bsdInfo.pbi_ppid),
                name: name,
                path: path,
                rssBytes: rusage.ri_resident_size,
                footprintBytes: rusage.ri_phys_footprint,
                cpuFraction: cpuFraction,
                euid: Int32(bitPattern: bsdInfo.pbi_uid),
                isStopped: bsdInfo.pbi_status == kSSTOP,
                isMCP: isMCP,
                startSeconds: TimeInterval(bsdInfo.pbi_start_tvsec),
                groupKey: key,
                groupDisplayName: display))
        }

        // Phase 2: adopt name-based groups into their ancestor app.
        var bundlePathByGroup: [String: String] = [:]
        for index in records.indices {
            let record = records[index]
            if record.groupKey.hasPrefix("app:")
                || record.groupKey == "sim" || record.groupKey == "codex" {
                continue
            }
            guard let (bundle, bundlePath) = ancestorApp(of: record.pid,
                                                         ppidByPid: ppidByPid,
                                                         pathByPid: pathByPid) else { continue }
            let group = ProcessTreeAggregator.appGroup(forBundle: bundle)
            bundlePathByGroup[group.key] = bundlePath
            records[index] = record.reassigned(toGroupKey: group.key,
                                               displayName: group.display)
        }

        // Drop cached state for pids that disappeared.
        let alive = seenPids
        lastCPUTimes = cpuTimes
        mcpFlags = mcpFlags.filter { alive.contains($0.key) }

        // Phase 3: aggregate by group.
        struct Accumulator {
            var rss: UInt64 = 0
            var footprint: UInt64 = 0
            var cpu: Double = 0
            var procs: [ProcessRecord] = []
            var display = ""
            var isApp = false
            var iconPath: String?
        }

        var accumulators: [String: Accumulator] = [:]
        for record in records {
            var acc = accumulators[record.groupKey] ?? Accumulator()
            acc.rss &+= record.rssBytes
            acc.footprint &+= record.footprintBytes
            acc.cpu += record.cpuFraction
            acc.procs.append(record)
            if acc.procs.count == 1 {
                let key = record.groupKey
                acc.display = record.groupDisplayName
                acc.isApp = key.hasPrefix("app:") || key == "sim" || key == "codex"
                acc.iconPath = ProcessTreeAggregator.appBundlePath(path: record.path)
                    ?? bundlePathByGroup[key]
            }
            accumulators[record.groupKey] = acc
        }

        groupTrendRings = groupTrendRings.filter { accumulators[$0.key] != nil }

        var groups: [ProcessGroupInfo] = []
        groups.reserveCapacity(accumulators.count)
        let nowEpoch = now.timeIntervalSince1970
        for (key, acc) in accumulators {
            let trend = trends(for: key, now: now, rss: acc.rss, footprint: acc.footprint)

            // Orphan/stale dev workload: no live parent app adopted it
            // (name-based group), its heavy processes were reparented to
            // launchd, it is old, idle, and still holding hundreds of MB —
            // e.g. an MCP server or gradle daemon left behind by an editor
            // or build that already exited.
            let unadopted = !(key.hasPrefix("app:") || key == "sim")
            let heavyProcs = acc.procs.filter { $0.rssBytes > 50 * 1_048_576 }
            let orphaned = !heavyProcs.isEmpty
                && heavyProcs.allSatisfy { $0.ppid == 1 }
            var maxAge: TimeInterval = 0
            for proc in acc.procs where proc.startSeconds > 0 {
                maxAge = max(maxAge, nowEpoch - proc.startSeconds)
            }
            let isStale = unadopted
                && max(acc.rss, acc.footprint) > 200 * 1_048_576
                && acc.cpu < 0.5
                && orphaned
                && maxAge > 1800

            groups.append(ProcessGroupInfo(
                key: key,
                displayName: acc.display,
                isApp: acc.isApp,
                iconPath: acc.iconPath,
                totalRSS: acc.rss,
                totalFootprint: acc.footprint,
                cpuFraction: acc.cpu,
                processes: acc.procs.sorted { $0.rssBytes > $1.rssBytes },
                trendBytesPerMin: trend.rssPerMin,
                footprintTrendBytesPerMin: trend.footprintPerMin,
                isStaleWorkload: isStale,
                ageSeconds: maxAge))
        }
        groups.sort { $0.totalRSS > $1.totalRSS }

        let fastest = groups
            .map { (name: $0.displayName, bytesPerMin: max($0.footprintTrendBytesPerMin, $0.trendBytesPerMin)) }
            .filter { $0.bytesPerMin > 0 }
            .max { $0.bytesPerMin < $1.bytesPerMin }

        onScan?(Output(groups: groups,
                       fastestGrowing: fastest,
                       stats: ScanStats(totalPids: Int(count), rusageReads: rusageReads)))
    }

    /// Walks the ppid chain (≤ 12 hops, cycle-safe) looking for an ancestor
    /// that lives inside an app bundle.
    private func ancestorApp(of pid: Int32,
                             ppidByPid: [Int32: Int32],
                             pathByPid: [Int32: String]) -> (bundle: String, bundlePath: String)? {
        var current = ppidByPid[pid] ?? 0
        var depth = 0
        var visited = Set<Int32>()
        while current > 0, depth < 12, visited.insert(current).inserted {
            if let parentPath = pathByPid[current],
               let bundlePath = ProcessTreeAggregator.appBundlePath(path: parentPath),
               let bundle = ProcessTreeAggregator.appBundleName(path: parentPath) {
                return (bundle, bundlePath)
            }
            current = ppidByPid[current] ?? 0
            depth += 1
        }
        return nil
    }

    // MARK: - Trend

    /// Appends a sample to the group's ring and returns (RSS, footprint)
    /// bytes/min across a ~5-minute window (0 when span < 45s). Signed
    /// deltas so shrinkage never wraps UInt64.
    private func trends(for key: String, now: Date, rss: UInt64, footprint: UInt64)
        -> (rssPerMin: Double, footprintPerMin: Double) {
        var ring = groupTrendRings[key] ?? []
        ring.append((now, rss, footprint))
        ring.removeAll { $0.t < now.addingTimeInterval(-600) }
        groupTrendRings[key] = ring
        guard let first = ring.first, let last = ring.last, last.t > first.t else { return (0, 0) }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= 45 else { return (0, 0) }
        let rssRate = (Double(last.rss) - Double(first.rss)) / span * 60.0
        let fpRate = (Double(last.footprint) - Double(first.footprint)) / span * 60.0
        return (rssRate, fpRate)
    }

    // MARK: - argv

    /// Reads argv via the public `KERN_PROCARGS2` sysctl (values from
    /// <sys/sysctl.h>; used by ps(1)). Returns [] on failure (e.g. root-owned).
    private func readArguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [kCTL_KERN, kKERN_PROCARGS2, pid]
        var buffer = [CChar](repeating: 0, count: 8192)
        var size = 8192
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }

        let argc = buffer.withUnsafeBytes { raw in
            Int(raw.loadUnaligned(fromByteOffset: 0, as: Int32.self))
        }
        guard argc > 0, argc < 2048 else { return nil }

        var args: [String] = []
        var offset = 4
        let end = size
        for _ in 0..<argc {
            guard offset < end else { break }
            let start = offset
            while offset < end, buffer[offset] != 0 { offset += 1 }
            guard offset > start else { break }
            let bytes = buffer[start..<offset].lazy.map { UInt8(bitPattern: $0) }
            args.append(String(decoding: bytes, as: UTF8.self))
            offset += 1 // skip NUL
        }
        return args
    }
}

private extension ProcessRecord {
    func reassigned(toGroupKey key: String, displayName: String) -> ProcessRecord {
        ProcessRecord(
            pid: pid, ppid: ppid, name: name, path: path,
            rssBytes: rssBytes, footprintBytes: footprintBytes,
            cpuFraction: cpuFraction, euid: euid, isStopped: isStopped, isMCP: isMCP,
            startSeconds: startSeconds,
            groupKey: key, groupDisplayName: displayName)
    }
}
