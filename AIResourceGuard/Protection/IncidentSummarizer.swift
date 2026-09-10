import Foundation

/// Rule-based post-mortem summary — no LLM, just clear rules over history.
/// Answers: when did it start, what did swap do, which task grew abnormally,
/// what did auto-protection do, when did it recover, and the most likely
/// cause.
enum IncidentSummarizer {

    private struct Episode {
        let indices: Range<Int>
        let peak: HistorySnapshot
        let peakScore: Int
        let duration: TimeInterval
    }

    static func summarize(snapshots: [HistorySnapshot], events: [HistoryEvent]) -> [String] {
        guard snapshots.count >= 2 else { return [] }

        // Split the window into episodes: contiguous runs of 注意 or worse.
        var episodes: [Episode] = []
        var runStart: Int?
        for (index, snapshot) in snapshots.enumerated() {
            if snapshot.riskLevel >= .warning {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                episodes.append(episode(snapshots: snapshots, range: start..<index))
                runStart = nil
            }
        }
        if let start = runStart {
            episodes.append(episode(snapshots: snapshots, range: start..<snapshots.count))
        }

        guard let worst = episodes.max(by: { $0.peakScore < $1.peakScore }) else {
            return ["该时段内系统整体保持正常，未出现需要处理的风险时段。"]
        }

        let start = snapshots[worst.indices.lowerBound]
        let end = snapshots[worst.indices.upperBound - 1]
        let peak = worst.peak
        let recovered = snapshots[worst.indices.upperBound...].first { $0.riskLevel == .normal }

        var lines: [String] = []

        // 1. Trajectory.
        var line1 = "\(time(start.timestamp)) 起风险升至「\(start.riskLevel.label)」"
        if peak.timestamp > start.timestamp {
            line1 += "，\(time(peak.timestamp)) 达到峰值（\(peak.riskLevel.label)，Swap \(fmtBytes(peak.swapUsedBytes))）"
        }
        if let recovered {
            line1 += "，\(time(recovered.timestamp)) 恢复正常"
            let minutes = Int(recovered.timestamp.timeIntervalSince(start.timestamp) / 60)
            line1 += minutes > 0 ? "，持续约 \(minutes) 分钟。" : "。"
        } else {
            line1 += "，尚未完全恢复。"
        }
        lines.append(line1)

        // 2. Swap behaviour.
        let swapDelta = Double(peak.swapUsedBytes) - Double(start.swapUsedBytes)
        let maxRate = snapshots[worst.indices]
            .map { $0.swapRateBytesPerMin / 1_048_576 }
            .max() ?? 0
        if abs(swapDelta) > 512 * 1_048_576 || maxRate > 100 {
            lines.append("Swap 从 \(fmtBytes(start.swapUsedBytes)) "
                + (swapDelta >= 0 ? "升至" : "回落至")
                + " \(fmtBytes(peak.swapUsedBytes))（\(swapDelta >= 0 ? "+" : "")\(fmtBytes(UInt64(abs(swapDelta))))）"
                + (maxRate >= 50 ? "，峰值增速 \(String(format: "%.0f", maxRate)) MB/分钟" : "")
                + "。")
        }

        // 3. Abnormally growing task: max (peak − start) RSS per name over
        //    the window, using top-entry samples.
        if let group = worstGrowth(snapshots: snapshots, range: worst.indices) {
            lines.append("期间 \(group.name) 内存从 \(fmtBytes(group.startBytes)) 增至 "
                + "\(fmtBytes(group.peakBytes))（+\(fmtBytes(group.peakBytes - group.startBytes))），"
                + "为增长最异常的任务。")
        }

        // 4. Protection actions during (or just after) the episode.
        let actionLines = events
            .filter { $0.kind == "action" && $0.timestamp >= start.timestamp && $0.timestamp <= end.timestamp.addingTimeInterval(120) }
            .prefix(5)
            .map { "\(time($0.timestamp)) \($0.summary)" }
        if actionLines.isEmpty {
            lines.append("期间未执行自动保护动作（自动保护未开启或未达到触发条件）。")
        } else {
            lines.append("保护动作：\n" + actionLines.joined(separator: "\n"))
        }

        // 5. Most likely cause.
        lines.append(causeLine(snapshots: snapshots, range: worst.indices,
                               start: start, maxRate: maxRate))

        return lines
    }

    // MARK: - Helpers

    private static func episode(snapshots: [HistorySnapshot], range: Range<Int>) -> Episode {
        let slice = snapshots[range]
        let peak = slice.max { lhs, rhs in
            (lhs.riskLevel.rawValue, lhs.swapUsedBytes) < (rhs.riskLevel.rawValue, rhs.swapUsedBytes)
        } ?? slice.first!
        let score = peak.riskLevel.rawValue * 1_000_000_000 + Int(peak.swapUsedBytes / 1_048_576)
        let duration = slice.last!.timestamp.timeIntervalSince(slice.first!.timestamp)
        return Episode(indices: range, peak: peak, peakScore: score, duration: duration)
    }

    private struct GrowthGroup {
        let name: String
        let startBytes: UInt64
        let peakBytes: UInt64
    }

    private static func worstGrowth(snapshots: [HistorySnapshot], range: Range<Int>) -> GrowthGroup? {
        let episode = snapshots[range]
        let earlier = snapshots[..<range.lowerBound].suffix(6)
        var startBytes: [String: UInt64] = [:]
        for snapshot in earlier {
            for entry in snapshot.top {
                startBytes[entry.name, default: entry.rssBytes] = entry.rssBytes
            }
        }
        // No pre-episode samples → use the episode's own first sightings.
        for snapshot in episode.prefix(2) {
            for entry in snapshot.top where startBytes[entry.name] == nil {
                startBytes[entry.name] = entry.rssBytes
            }
        }

        var peakBytes: [String: UInt64] = [:]
        for snapshot in episode {
            for entry in snapshot.top {
                peakBytes[entry.name] = max(peakBytes[entry.name] ?? 0, entry.rssBytes)
            }
        }

        return peakBytes
            .compactMap { name, peak -> GrowthGroup? in
                guard let start = startBytes[name], peak > start,
                      peak - start > 200 * 1_048_576 else { return nil }
                return GrowthGroup(name: name, startBytes: start, peakBytes: peak)
            }
            .max { ($0.peakBytes - $0.startBytes) < ($1.peakBytes - $1.startBytes) }
    }

    private static func causeLine(snapshots: [HistorySnapshot], range: Range<Int>,
                                  start: HistorySnapshot, maxRate: Double) -> String {
        let group = worstGrowth(snapshots: snapshots, range: range)
        if maxRate >= 300, let group {
            return "最可能原因：\(group.name) 快速增长（+\(fmtBytes(group.peakBytes - group.startBytes))）把系统推入 Swap，峰值增速 \(String(format: "%.0f", maxRate)) MB/分钟。"
        }
        if maxRate >= 300 {
            return "最可能原因：多个任务内存需求同时上升，Swap 快速增长（峰值 \(String(format: "%.0f", maxRate)) MB/分钟），未见单一异常进程。"
        }
        if let group {
            return "最可能原因：\(group.name) 内存持续增长，逐步挤压可用内存。"
        }
        return "最可能原因：任务总内存需求超过物理容量，Swap 长期处于 \(fmtBytes(start.swapUsedBytes)) 以上的高位。"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
