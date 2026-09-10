import Foundation

/// Ranks candidate groups for auto-pause by *rescue value*, replacing the
/// old "biggest first" heuristic. A good rescue target releases a lot of
/// memory, is abnormally growing or stale, runs in the background, and is
/// unlikely to be what the user is currently looking at.
///
/// Factors (higher = better rescue target):
/// - expected memory release — log-scaled RSS (a 4 GB group is ~2× a 1 GB one,
///   not 4×; the first GB matters most on a 16 GB machine)
/// - abnormal growth (risk source) or RSS far above the group's own baseline
/// - stale/orphaned workloads are pure wins (nobody is using them)
/// - GUI app groups carry a mild penalty (someone may have them open)
/// - the frontmost app is protected with a strong multiplier — pausing what
///   the user is actively looking at is the most disruptive action possible
enum RescueScorer {
    static func score(group: ProcessGroupInfo,
                      isForeground: Bool,
                      baselineMeanFootprintMB: Double?) -> Double {
        let footprintMB = Double(group.totalFootprint) / 1_048_576

        var score = log2(footprintMB / 200 + 1) // 200MB→1.0, 1GB→2.3, 4GB→3.4, 12GB→4.6

        if group.isRiskSource { score += 1.2 }
        if let baseline = baselineMeanFootprintMB, baseline > 50, footprintMB > baseline + 1024 {
            score += 0.8
        }
        if group.isStaleWorkload { score += 1.5 }

        if group.isApp { score *= 0.8 }
        if isForeground { score *= 0.15 }

        return max(0, score)
    }
}
