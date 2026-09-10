import Foundation

/// One metric's rolling statistics. Uses an exponentially-weighted mean and
/// variance (Welford-style update, α clamped early so the first samples act
/// like a plain average). Effective window ≈ 1/α samples, so the baseline
/// adapts to slow drift within ~15 minutes but a single incident cannot
/// move it.
struct MetricStats {
    private let alpha: Double
    private(set) var count = 0
    private(set) var mean = 0.0
    private(set) var variance = 0.0

    init(alpha: Double = 0.005) {
        self.alpha = alpha
    }

    var isReady: Bool { count >= 60 }
    var stddev: Double { sqrt(max(variance, 0)) }

    mutating func add(_ value: Double) {
        count += 1
        // Warm-up: behave like a running average until 1/count drops below
        // α, then cap the effective window at ≈1/α samples.
        let a = max(alpha, 1.0 / Double(count))
        let d = value - mean
        mean += a * d
        variance = (1 - a) * (variance + a * d * d)
    }
}

/// Snapshot of baseline state passed into RiskInput each evaluation.
struct BaselineContext {
    var ready = false
    var swapMeanMB = 0.0
    var swapStdMB = 0.0
    var pageoutMean = 0.0
    var pageoutReady = false
    var decompressionMean = 0.0
    var decompressionReady = false
    /// Groups whose current RSS is far above their own normal (worst first).
    var deviatingGroups: [(name: String, currentMB: Double, baselineMeanMB: Double)] = []
}

/// Learns what "normal" looks like *on this machine*: swap usage, page-out
/// rate, decompression churn and per-group RSS. Updated only while the risk
/// level is 正常/注意 so real incidents never pollute the baseline.
///
/// On startup it bootstraps from the last 24h of history snapshots (normal
/// ones only), so the baseline is useful immediately instead of after hours
/// of observation. Fixed safety thresholds still apply — baseline deviation
/// is an additional, machine-relative layer.
final class BaselineTracker {
    private(set) var swapUsedMB = MetricStats()
    private(set) var pageoutRate = MetricStats()
    private(set) var decompressionRate = MetricStats()
    private var groupRSSMB: [String: MetricStats] = [:]

    // MARK: - Learning

    func recordNormalSystem(sample: SystemSample) {
        swapUsedMB.add(Double(sample.swapUsedBytes) / 1_048_576)
        pageoutRate.add(sample.pageoutRate)
        decompressionRate.add(sample.decompressionRate)
    }

    func recordNormalGroups(_ groups: [ProcessGroupInfo]) {
        for group in groups {
            let mb = Double(group.totalRSS) / 1_048_576
            if mb > 50 { // ignore noise from short-lived tiny processes
                groupRSSMB[group.displayName, default: MetricStats()].add(mb)
            }
        }
    }

    /// Seed swap + group-RSS baselines from persisted snapshots (normal only).
    func bootstrap(from snapshots: [HistorySnapshot]) {
        for snapshot in snapshots where snapshot.riskLevel == .normal {
            swapUsedMB.add(Double(snapshot.swapUsedBytes) / 1_048_576)
            for entry in snapshot.top {
                let mb = Double(entry.rssBytes) / 1_048_576
                if mb > 50 {
                    groupRSSMB[entry.name, default: MetricStats()].add(mb)
                }
            }
        }
    }

    // MARK: - Queries

    func groupMeanRSSMB(displayName: String) -> Double? {
        guard let stats = groupRSSMB[displayName], stats.isReady else { return nil }
        return stats.mean
    }

    /// Builds the machine-relative context for one risk evaluation.
    func context(sample: SystemSample, groups: [ProcessGroupInfo]) -> BaselineContext {
        var context = BaselineContext()
        context.ready = swapUsedMB.isReady
        context.swapMeanMB = swapUsedMB.mean
        context.swapStdMB = swapUsedMB.stddev
        context.pageoutMean = pageoutRate.mean
        context.pageoutReady = pageoutRate.isReady
        context.decompressionMean = decompressionRate.mean
        context.decompressionReady = decompressionRate.isReady

        var deviations: [(String, Double, Double)] = []
        for group in groups {
            guard let stats = groupRSSMB[group.displayName], stats.isReady else { continue }
            let current = Double(group.totalRSS) / 1_048_576
            let excess = current - stats.mean
            let floor = max(1024.0, 2 * stats.stddev)
            if excess > floor {
                deviations.append((group.displayName, current, stats.mean))
            }
        }
        context.deviatingGroups = deviations
            .sorted { ($0.1 - $0.2) > ($1.1 - $1.2) }
            .prefix(3)
            .map { (name: $0.0, currentMB: $0.1, baselineMeanMB: $0.2) }
        return context
    }
}
