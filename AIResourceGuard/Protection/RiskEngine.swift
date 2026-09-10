import Foundation

/// Multi-signal risk scoring with a hysteresis state machine.
///
/// Score = max(signal severities) + 0.05 per extra signal ≥ 0.4, capped at 1.
/// Escalation requires the *same* higher level sustained for
/// 12s/10s/6s (注意/压力较高/即将失控); de-escalation requires the score to
/// stay below (threshold − margin) for 30s. A level is only notified at most
/// once per cooldown window. All timing comes from `RiskInput.timestamp`,
/// which makes the engine fully unit-testable.
///
/// Output is human-language, not metric dumps: `headline` is the single
/// sentence the popover shows ("Swap 正在快速增长"), `reasons` are the
/// supporting detail lines for history and notifications.
final class RiskEngine {
    var thresholdsProvider: () -> ThresholdConfig

    private(set) var level: RiskLevel = .normal
    private var pendingLevel: RiskLevel?
    private var pendingSince: Date?
    private var lastNotifyAt: [RiskLevel: Date] = [:]
    private var levelSince: Date?

    init(thresholdsProvider: @escaping () -> ThresholdConfig = { ThresholdConfig() }) {
        self.thresholdsProvider = thresholdsProvider
    }

    private struct Signal {
        let severity: Double
        let sentence: String
        let detail: String
    }

    // MARK: - Evaluation

    func evaluate(_ input: RiskInput) -> RiskAssessment {
        let cfg = thresholdsProvider()
        let now = input.timestamp
        let previous = level

        var signals: [Signal] = []

        switch input.pressure {
        case .critical:
            signals.append(Signal(severity: 1.0,
                                  sentence: "系统内存压力持续处于高位",
                                  detail: "内核内存压力：严重"))
        case .warning:
            signals.append(Signal(severity: 0.55,
                                  sentence: "系统内存压力升高",
                                  detail: "内核内存压力：警告"))
        case .normal:
            break
        }

        // Absolute swap usage is deliberately a *weak* signal (severity cap
        // 0.6): a machine can sit on several GB of swap for hours while the
        // kernel is comfortable. Danger/Critical are driven by pressure,
        // swap *rate*, thrashing and per-process growth instead.
        let swapMB = Double(input.swapUsedBytes) / 1_048_576
        if swapMB >= cfg.swapCriticalMB {
            signals.append(Signal(severity: 0.6,
                                  sentence: "Swap 已达到 \(fmtMB(swapMB))，接近上限",
                                  detail: "Swap \(fmtMB(swapMB))"))
        } else if swapMB >= cfg.swapDangerMB {
            signals.append(Signal(severity: 0.5,
                                  sentence: "Swap 已达到 \(fmtMB(swapMB))",
                                  detail: "Swap \(fmtMB(swapMB))"))
        } else if swapMB >= cfg.swapWarnMB {
            signals.append(Signal(severity: 0.45,
                                  sentence: "Swap 占用偏高",
                                  detail: "Swap \(fmtMB(swapMB))"))
        }

        let rateMB = input.swapRateBytesPerMin / 1_048_576
        if rateMB >= cfg.swapRateCriticalMBPerMin {
            signals.append(Signal(severity: 1.0,
                                  sentence: "Swap 正在快速增长",
                                  detail: "Swap 增速 \(fmtRate(input.swapRateBytesPerMin))"))
        } else if rateMB >= cfg.swapRateDangerMBPerMin {
            signals.append(Signal(severity: 0.8,
                                  sentence: "Swap 正在快速增长",
                                  detail: "Swap 增速 \(fmtRate(input.swapRateBytesPerMin))"))
        } else if rateMB >= cfg.swapRateWarnMBPerMin {
            signals.append(Signal(severity: 0.45,
                                  sentence: "Swap 正在增长",
                                  detail: "Swap 增速 \(fmtRate(input.swapRateBytesPerMin))"))
        }

        if input.memoryUsedFraction >= 0.97 {
            signals.append(Signal(severity: 0.8,
                                  sentence: "物理内存即将耗尽",
                                  detail: "物理内存 \(Int(input.memoryUsedFraction * 100))%"))
        } else if input.memoryUsedFraction >= 0.93 {
            signals.append(Signal(severity: 0.6,
                                  sentence: "内存占用很高",
                                  detail: "物理内存 \(Int(input.memoryUsedFraction * 100))%"))
        } else if input.memoryUsedFraction >= 0.90 {
            signals.append(Signal(severity: 0.45,
                                  sentence: "内存占用偏高",
                                  detail: "物理内存 \(Int(input.memoryUsedFraction * 100))%"))
        }

        if input.pageoutRate >= 800 {
            signals.append(Signal(severity: 1.0,
                                  sentence: "换页风暴，系统接近失速",
                                  detail: "换页 \(Int(input.pageoutRate)) 页/秒"))
        } else if input.pageoutRate >= 200 {
            signals.append(Signal(severity: 0.7,
                                  sentence: "系统正在剧烈换页",
                                  detail: "换页 \(Int(input.pageoutRate)) 页/秒"))
        } else if input.pageoutRate >= 50 {
            signals.append(Signal(severity: 0.4,
                                  sentence: "系统换页活动增加",
                                  detail: "换页 \(Int(input.pageoutRate)) 页/秒"))
        }

        // Decompression churn is a *supporting* signal: 16 GB machines doing
        // real work routinely sustain 10–30k pages/s of decompression while
        // the kernel is still comfortable. Only extreme churn scores high.
        if input.decompressionRate >= 100_000 {
            signals.append(Signal(severity: 0.8,
                                  sentence: "内存压缩/解压抖动严重",
                                  detail: "解压缩 \(Int(input.decompressionRate)) 页/秒"))
        } else if input.decompressionRate >= 50_000 {
            signals.append(Signal(severity: 0.5,
                                  sentence: "内存压缩活动剧烈",
                                  detail: "解压缩 \(Int(input.decompressionRate)) 页/秒"))
        } else if input.decompressionRate >= 20_000 {
            signals.append(Signal(severity: 0.4,
                                  sentence: "内存压缩活动加剧",
                                  detail: "解压缩 \(Int(input.decompressionRate)) 页/秒"))
        }

        let growthMB = input.topGrowthBytesPerMin / 1_048_576
        if growthMB >= 600, let group = input.topGrowthGroup {
            signals.append(Signal(severity: 0.85,
                                  sentence: "\(group) 是最近 5 分钟增长最快的应用",
                                  detail: "\(group) 增长 \(fmtRate(input.topGrowthBytesPerMin))"))
        } else if growthMB >= 250, let group = input.topGrowthGroup {
            signals.append(Signal(severity: 0.6,
                                  sentence: "\(group) 正在快速增长",
                                  detail: "\(group) 增长 \(fmtRate(input.topGrowthBytesPerMin))"))
        } else if growthMB >= 100, let group = input.topGrowthGroup {
            signals.append(Signal(severity: 0.4,
                                  sentence: "\(group) 内存增长较快",
                                  detail: "\(group) 增长 \(fmtRate(input.topGrowthBytesPerMin))"))
        }

        let score = Self.combine(signals)
        let sorted = signals.sorted { $0.severity > $1.severity }
        let reasons = sorted.prefix(4).map(\.detail)

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
                levelSince = now
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
                levelSince = now
                justDeescalated = true
            } else if pendingLevel != downTarget {
                pendingLevel = downTarget
                pendingSince = now
            }
        } else {
            pendingLevel = nil
            pendingSince = nil
        }

        if levelSince == nil { levelSince = now }
        let levelAge = now.timeIntervalSince(levelSince!)

        return RiskAssessment(
            level: level,
            previousLevel: previous,
            score: score,
            headline: headline(score: score, input: input, signals: sorted, config: cfg),
            reasons: reasons,
            dominantReason: reasons.first,
            justEscalated: justEscalated,
            justDeescalated: justDeescalated,
            shouldNotify: shouldNotify,
            levelAgeSeconds: max(0, levelAge))
    }

    // MARK: - Headline

    /// The single sentence for the popover. Composite sentences first (the
    /// combinations users actually need to read), then the dominant signal.
    private func headline(score: Double,
                          input: RiskInput,
                          signals: [Signal],
                          config cfg: ThresholdConfig) -> String {
        if score < cfg.warningScore {
            return "系统正常，无需处理"
        }

        let swapMB = Double(input.swapUsedBytes) / 1_048_576
        let rateMB = input.swapRateBytesPerMin / 1_048_576

        if swapMB >= cfg.swapDangerMB && rateMB >= cfg.swapRateWarnMBPerMin {
            return "Swap 已达到 \(fmtMB(swapMB))，并仍在快速增长"
        }
        if input.pressure == .critical && swapMB >= cfg.swapDangerMB {
            return "内存压力持续升高，Swap 已达到 \(fmtMB(swapMB))"
        }
        return signals.first?.sentence ?? "系统资源紧张"
    }

    // MARK: - Helpers

    private static func combine(_ signals: [Signal]) -> Double {
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
