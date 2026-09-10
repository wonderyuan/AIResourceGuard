import Foundation

/// Multi-signal risk scoring with a hysteresis state machine.
///
/// Score = max(signal severities) + 0.05 per extra signal ≥ 0.4, capped at 1.
/// Escalation requires the *same* higher level sustained for
/// 12s/10s/6s (Warning/Danger/Critical); de-escalation requires the score to
/// stay below (threshold − margin) for 30s. A level is only notified at most
/// once per cooldown window. All timing comes from `RiskInput.timestamp`,
/// which makes the engine fully unit-testable.
final class RiskEngine {
    var thresholdsProvider: () -> ThresholdConfig

    private(set) var level: RiskLevel = .normal
    private var pendingLevel: RiskLevel?
    private var pendingSince: Date?
    private var lastNotifyAt: [RiskLevel: Date] = [:]

    init(thresholdsProvider: @escaping () -> ThresholdConfig = { ThresholdConfig() }) {
        self.thresholdsProvider = thresholdsProvider
    }

    // MARK: - Evaluation

    func evaluate(_ input: RiskInput) -> RiskAssessment {
        let cfg = thresholdsProvider()
        let now = input.timestamp
        let previous = level

        var signals: [(severity: Double, reason: String)] = []

        switch input.pressure {
        case .critical:
            signals.append((1.0, "Kernel memory pressure: critical"))
        case .warning:
            signals.append((0.55, "Kernel memory pressure: warning"))
        case .normal:
            break
        }

        // Absolute swap usage is deliberately a *weak* signal (severity cap
        // 0.6): a machine can sit on several GB of swap for hours while the
        // kernel is comfortable. Danger/Critical are driven by pressure,
        // swap *rate*, thrashing and per-process growth instead.
        let swapMB = Double(input.swapUsedBytes) / 1_048_576
        if swapMB >= cfg.swapCriticalMB {
            signals.append((0.6, "Swap \(fmtMB(swapMB)) used"))
        } else if swapMB >= cfg.swapDangerMB {
            signals.append((0.5, "Swap \(fmtMB(swapMB)) used"))
        } else if swapMB >= cfg.swapWarnMB {
            signals.append((0.45, "Swap \(fmtMB(swapMB)) used"))
        }

        let rateMB = input.swapRateBytesPerMin / 1_048_576
        if rateMB >= cfg.swapRateCriticalMBPerMin {
            signals.append((1.0, "Swap growing \(fmtMB(rateMB))/min"))
        } else if rateMB >= cfg.swapRateDangerMBPerMin {
            signals.append((0.8, "Swap growing \(fmtMB(rateMB))/min"))
        } else if rateMB >= cfg.swapRateWarnMBPerMin {
            signals.append((0.45, "Swap growing \(fmtMB(rateMB))/min"))
        }

        if input.memoryUsedFraction >= 0.97 {
            signals.append((0.8, "Physical memory \(Int(input.memoryUsedFraction * 100))% used"))
        } else if input.memoryUsedFraction >= 0.93 {
            signals.append((0.6, "Physical memory \(Int(input.memoryUsedFraction * 100))% used"))
        } else if input.memoryUsedFraction >= 0.90 {
            signals.append((0.45, "Physical memory \(Int(input.memoryUsedFraction * 100))% used"))
        }

        if input.pageoutRate >= 800 {
            signals.append((1.0, "Heavy page-outs \(Int(input.pageoutRate))/s"))
        } else if input.pageoutRate >= 200 {
            signals.append((0.7, "Page-outs \(Int(input.pageoutRate))/s"))
        } else if input.pageoutRate >= 50 {
            signals.append((0.4, "Page-outs \(Int(input.pageoutRate))/s"))
        }

        // Decompression churn is a *supporting* signal: 16 GB machines doing
        // real work routinely sustain 10–30k pages/s of decompression while
        // the kernel is still comfortable. Only extreme churn scores high.
        if input.decompressionRate >= 100_000 {
            signals.append((0.8, "Extreme decompression \(Int(input.decompressionRate))/s"))
        } else if input.decompressionRate >= 50_000 {
            signals.append((0.5, "Heavy decompression \(Int(input.decompressionRate))/s"))
        } else if input.decompressionRate >= 20_000 {
            signals.append((0.4, "Decompression \(Int(input.decompressionRate))/s"))
        }

        let growthMB = input.topGrowthBytesPerMin / 1_048_576
        if growthMB >= 600, let group = input.topGrowthGroup {
            signals.append((0.85, "\(group) growing \(fmtMB(growthMB))/min"))
        } else if growthMB >= 250, let group = input.topGrowthGroup {
            signals.append((0.6, "\(group) growing \(fmtMB(growthMB))/min"))
        } else if growthMB >= 100, let group = input.topGrowthGroup {
            signals.append((0.4, "\(group) growing \(fmtMB(growthMB))/min"))
        }

        let score = Self.combine(signals)
        let reasons = signals
            .sorted { $0.severity > $1.severity }
            .prefix(4)
            .map(\.reason)

        let upTarget = level(forScore: score, config: cfg)
        let downTarget = level(forScore: score + cfg.deescalationMargin, config: cfg)

        var justEscalated = false
        var justDeescalated = false
        var shouldNotify = false

        if upTarget.rawValue > level.rawValue {
            if pendingLevel == upTarget, let since = pendingSince,
               now.timeIntervalSince(since) >= sustain(for: upTarget, config: cfg) {
                level = upTarget
                pendingLevel = nil
                pendingSince = nil
                justEscalated = true
                if level >= .warning,
                   let last = lastNotifyAt[level],
                   now.timeIntervalSince(last) < cfg.notifyCooldownSeconds {
                    shouldNotify = false
                } else if level >= .warning {
                    lastNotifyAt[level] = now
                    shouldNotify = true
                }
            } else if pendingLevel != upTarget {
                pendingLevel = upTarget
                pendingSince = now
            }
        } else if downTarget.rawValue < level.rawValue {
            if pendingLevel == downTarget, let since = pendingSince,
               now.timeIntervalSince(since) >= cfg.deescalateSeconds {
                level = downTarget
                pendingLevel = nil
                pendingSince = nil
                justDeescalated = true
            } else if pendingLevel != downTarget {
                pendingLevel = downTarget
                pendingSince = now
            }
        } else {
            pendingLevel = nil
            pendingSince = nil
        }

        return RiskAssessment(
            level: level,
            previousLevel: previous,
            score: score,
            reasons: reasons,
            dominantReason: reasons.first,
            justEscalated: justEscalated,
            justDeescalated: justDeescalated,
            shouldNotify: shouldNotify)
    }

    // MARK: - Helpers

    private static func combine(_ signals: [(severity: Double, reason: String)]) -> Double {
        guard !signals.isEmpty else { return 0 }
        let maxSeverity = signals.map(\.severity).max() ?? 0
        let extras = max(0, signals.filter { $0.severity >= 0.4 }.count - 1)
        return min(1.0, maxSeverity + Double(extras) * 0.05)
    }

    private func level(forScore score: Double, config: ThresholdConfig) -> RiskLevel {
        if score >= config.criticalScore { return .critical }
        if score >= config.dangerScore { return .danger }
        if score >= config.warningScore { return .warning }
        return .normal
    }

    private func sustain(for level: RiskLevel, config: ThresholdConfig) -> Double {
        switch level {
        case .warning: return config.sustainWarningSeconds
        case .danger: return config.sustainDangerSeconds
        case .critical: return config.sustainCriticalSeconds
        case .normal: return config.deescalateSeconds
        }
    }
}
