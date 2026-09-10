import Foundation

/// One complete pressure episode, derived from persisted history:
/// Normal → 注意/压力较高/即将失控 → 恢复. Deriving from snapshots makes
/// episodes crash-resilient — even a hard lockup leaves the story behind.
struct PressureEpisode: Identifiable {
    var id: Int { Int(startedAt.timeIntervalSince1970) }
    let startedAt: Date
    /// When the system was back to normal (nil while ongoing / cut off).
    let endedAt: Date?
    let peakRisk: RiskLevel
    let peakRiskAt: Date
    let peakSwapBytes: UInt64
    let peakSwapAt: Date
    let maxSwapRateBytesPerMin: Double
    /// Apps that grew abnormally during the episode, worst first.
    let suspects: [Suspect]
    /// Protection action events inside the episode window.
    let actions: [HistoryEvent]
    /// Start swap level, for the "+X GB" narrative.
    let startSwapBytes: UInt64
    let durationSeconds: TimeInterval

    struct Suspect: Identifiable {
        let name: String
        let startBytes: UInt64
        let peakBytes: UInt64
        var id: String { name }
        var growthBytes: UInt64 { peakBytes > startBytes ? peakBytes - startBytes : 0 }
    }

    var primarySuspect: Suspect? { suspects.first }
}

/// Splits a snapshot timeline into episodes and enriches each with peaks,
/// suspects and actions. Pure function over persisted data.
enum EpisodeBuilder {

    static func build(snapshots: [HistorySnapshot], events: [HistoryEvent]) -> [PressureEpisode] {
        guard snapshots.count >= 2 else { return [] }

        // Episodes: contiguous runs of risk >= 注意.
        var runs: [Range<Int>] = []
        var runStart: Int?
        for (index, snapshot) in snapshots.enumerated() {
            if snapshot.riskLevel >= .warning {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append(start..<index)
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start..<snapshots.count) }

        return runs.compactMap { range in
            episode(snapshots: snapshots, range: range, events: events)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    private static func episode(snapshots: [HistorySnapshot],
                                range: Range<Int>,
                                events: [HistoryEvent]) -> PressureEpisode? {
        let slice = snapshots[range]
        guard let first = slice.first, let last = slice.last else { return nil }

        let peak = slice.max { lhs, rhs in
            (lhs.riskLevel.rawValue, lhs.swapUsedBytes) < (rhs.riskLevel.rawValue, rhs.swapUsedBytes)
        } ?? first
        let peakSwap = slice.max { $0.swapUsedBytes < $1.swapUsedBytes } ?? first
        let maxRate = slice.map(\.swapRateBytesPerMin).max() ?? 0

        // Recovery: first normal snapshot after the run (nil if the window
        // ends mid-episode).
        var endedAt: Date?
        if range.upperBound < snapshots.count {
            endedAt = snapshots[range.upperBound].timestamp
        }

        // Suspects: per-name (start → peak) footprint over the episode and a
        // few snapshots before it.
        let leadIn = snapshots[..<range.lowerBound].suffix(4)
        var startBytes: [String: UInt64] = [:]
        for snapshot in leadIn {
            for entry in snapshot.top where startBytes[entry.name] == nil {
                startBytes[entry.name] = max(entry.footprintBytes, entry.rssBytes)
            }
        }
        for snapshot in slice.prefix(2) {
            for entry in snapshot.top where startBytes[entry.name] == nil {
                startBytes[entry.name] = max(entry.footprintBytes, entry.rssBytes)
            }
        }
        var peakBytes: [String: UInt64] = [:]
        for snapshot in slice {
            for entry in snapshot.top {
                peakBytes[entry.name] = max(peakBytes[entry.name] ?? 0,
                                            max(entry.footprintBytes, entry.rssBytes))
            }
        }
        let suspects = peakBytes
            .compactMap { name, peak -> PressureEpisode.Suspect? in
                guard let start = startBytes[name], peak > start,
                      peak - start > 200 * 1_048_576 else { return nil }
                return PressureEpisode.Suspect(name: name, startBytes: start, peakBytes: peak)
            }
            .sorted { $0.growthBytes > $1.growthBytes }
            .prefix(3)
            .map { $0 }

        // Protection actions inside the episode (plus a small tail).
        let windowEnd = endedAt ?? last.timestamp
        let actions = events.filter {
            $0.kind == "action"
                && $0.timestamp >= first.timestamp
                && $0.timestamp <= windowEnd.addingTimeInterval(120)
        }

        return PressureEpisode(
            startedAt: first.timestamp,
            endedAt: endedAt,
            peakRisk: peak.riskLevel,
            peakRiskAt: peak.timestamp,
            peakSwapBytes: peakSwap.swapUsedBytes,
            peakSwapAt: peakSwap.timestamp,
            maxSwapRateBytesPerMin: maxRate,
            suspects: suspects,
            actions: actions,
            startSwapBytes: first.swapUsedBytes,
            durationSeconds: windowEnd.timeIntervalSince(first.timestamp))
    }
}
