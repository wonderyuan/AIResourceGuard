import Foundation
import Darwin

/// System-wide memory / swap / CPU metrics from public Mach + sysctl APIs:
/// `host_statistics64(HOST_VM_INFO64)`, `sysctlbyname("vm.swapusage")`,
/// `sysctlbyname("hw.memsize")`, `host_processor_info(HOST_CPU_LOAD_INFO)`.
final class SystemMetricsMonitor {
    var onSample: ((SystemSample) -> Void)?
    /// Latest kernel pressure level, kept in sync by MemoryPressureMonitor.
    var currentPressure: PressureLevel = .normal

    private let queue = DispatchQueue(label: "local.dev.AIResourceGuard.system", qos: .utility)
    private var generation = 0
    private var interval: TimeInterval = 5
    private var isRunning = false

    private var lastSampleAt: Date?
    private var lastCPU: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastCounters: (pageins: UInt64, pageouts: UInt64,
                               compressions: UInt64, decompressions: UInt64)?
    private var swapHistory: [(t: Date, used: UInt64)] = []
    private let pageSize = Int(vm_kernel_page_size)

    // MARK: - Lifecycle

    func start(interval: TimeInterval) {
        self.interval = interval
        guard !isRunning else { return }
        isRunning = true
        queue.async { [weak self] in self?.sampleOnce() } // first sample immediately
        scheduleNext()
    }

    func stop() {
        isRunning = false
        generation += 1
    }

    /// Applies on the next scheduled tick (≤ interval seconds away).
    func setInterval(_ newInterval: TimeInterval) {
        interval = newInterval
    }

    /// Immediate out-of-band sample (used on pressure events).
    func sampleNow() {
        queue.async { [weak self] in self?.sampleOnce() }
    }

    private func scheduleNext() {
        generation += 1
        let g = generation
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.isRunning, self.generation == g else { return }
            self.sampleOnce()
            self.scheduleNext()
        }
    }

    // MARK: - Sampling

    private func sampleOnce() {
        let now = Date()
        guard let vm = readVMStats() else { return }

        let usedPages = UInt64(vm.wire_count) + UInt64(vm.active_count) + UInt64(vm.compressor_page_count)
        let cachedPages = UInt64(vm.inactive_count) + UInt64(vm.speculative_count)
        let physical = readPhysicalTotal()
        let swap = readSwapUsage()

        // Per-second rates against the previous tick.
        var pageinRate = 0.0, pageoutRate = 0.0
        var compRate = 0.0, decompRate = 0.0
        if let last = lastSampleAt, let c = lastCounters {
            let dt = max(now.timeIntervalSince(last), 0.25)
            pageinRate = Double(vm.pageins &- c.pageins) / dt
            pageoutRate = Double(vm.pageouts &- c.pageouts) / dt
            compRate = Double(vm.compressions &- c.compressions) / dt
            decompRate = Double(vm.decompressions &- c.decompressions) / dt
        }
        lastSampleAt = now
        lastCounters = (vm.pageins, vm.pageouts, vm.compressions, vm.decompressions)

        // Swap growth over a ~60s sliding window (min span 20s).
        // Signed delta: swap shrinking must not wrap UInt64.
        var swapRatePerMin = 0.0
        if let swap {
            swapHistory.append((now, swap.used))
            swapHistory.removeAll { $0.t < now.addingTimeInterval(-130) }
            let windowStart = now.addingTimeInterval(-60)
            if let first = swapHistory.first(where: { $0.t >= windowStart }),
               let last = swapHistory.last, last.t > first.t {
                let span = last.t.timeIntervalSince(first.t)
                if span >= 20 {
                    swapRatePerMin = (Double(last.used) - Double(first.used)) / span * 60.0
                }
            }
        }

        let sample = SystemSample(
            timestamp: now,
            pressure: currentPressure,
            physicalTotalBytes: physical,
            usedBytes: usedPages * UInt64(pageSize),
            cachedBytes: cachedPages * UInt64(pageSize),
            compressedBytes: UInt64(vm.compressor_page_count) * UInt64(pageSize),
            freeBytes: UInt64(vm.free_count) * UInt64(pageSize),
            swapUsedBytes: swap?.used ?? 0,
            swapTotalBytes: swap?.total ?? 0,
            swapRateBytesPerMin: swapRatePerMin,
            pageinRate: pageinRate,
            pageoutRate: pageoutRate,
            decompressionRate: decompRate,
            compressionRate: compRate,
            cpuUsage: readCPUUsage())

        onSample?(sample)
    }

    // MARK: - Raw reads

    private func readVMStats() -> vm_statistics64_data_t? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &count)
            }
        }
        return kr == KERN_SUCCESS ? vm : nil
    }

    private func readPhysicalTotal() -> UInt64 {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.stride
        _ = sysctlbyname("hw.memsize", &value, &len, nil, 0)
        return value
    }

    private func readSwapUsage() -> (used: UInt64, total: UInt64)? {
        var swap = xsw_usage()
        var len = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &swap, &len, nil, 0) == 0 else { return nil }
        return (used: swap.xsu_used, total: swap.xsu_total)
    }

    /// Total CPU utilization 0...1 from HOST_CPU_LOAD_INFO tick deltas.
    private func readCPUUsage() -> Double {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        let kr = host_processor_info(mach_host_self(), HOST_CPU_LOAD_INFO,
                                     &processorCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let ptr = info else { return 0 }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, UInt(bitPattern: ptr), size)
        }

        // processor_cpu_load_info layout per CPU: user, system, idle, nice.
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for cpu in 0..<Int(processorCount) {
            let base = cpu * 4
            user &+= UInt64(ptr[base])
            system &+= UInt64(ptr[base + 1])
            idle &+= UInt64(ptr[base + 2])
            nice &+= UInt64(ptr[base + 3])
        }
        defer { lastCPU = (user, system, idle, nice) }

        guard let last = lastCPU else { return 0 }
        let idleDelta = Double(idle &- last.idle)
        let totalDelta = Double((user &- last.user) + (system &- last.system)
                                + (idle &- last.idle) + (nice &- last.nice))
        guard totalDelta > 0 else { return 0 }
        return min(1.0, max(0.0, 1.0 - idleDelta / totalDelta))
    }
}
