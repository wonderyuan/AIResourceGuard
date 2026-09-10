import XCTest
@testable import AIResourceGuard

final class RiskEngineTests: XCTestCase {
    private let config = ThresholdConfig()

    private func engine() -> RiskEngine {
        RiskEngine(thresholdsProvider: { self.config })
    }

    private func input(
        at seconds: TimeInterval,
        pressure: PressureLevel = .normal,
        swapMB: Double = 0,
        swapRateMBPerMin: Double = 0,
        usedFraction: Double = 0.5,
        pageoutRate: Double = 0,
        decompressionRate: Double = 0,
        growthMBPerMin: Double = 0
    ) -> RiskInput {
        RiskInput(
            timestamp: Date(timeIntervalSinceReferenceDate: seconds),
            pressure: pressure,
            memoryUsedFraction: usedFraction,
            swapUsedBytes: UInt64(swapMB * 1_048_576),
            swapRateBytesPerMin: swapRateMBPerMin * 1_048_576,
            pageoutRate: pageoutRate,
            decompressionRate: decompressionRate,
            topGrowthBytesPerMin: growthMBPerMin * 1_048_576,
            topGrowthGroup: growthMBPerMin > 0 ? "Cursor" : nil)
    }

    // MARK: - Baseline

    func testHealthySystemStaysNormal() {
        let engine = engine()
        var t: TimeInterval = 0
        for _ in 0..<30 {
            let result = engine.evaluate(input(at: t))
            XCTAssertEqual(result.level, .normal)
            XCTAssertFalse(result.shouldNotify)
            t += 5
        }
    }

    // MARK: - Escalation requires sustain

    func testSustainedWarningEscalatesAndNotifiesOnce() {
        let engine = engine()
        var notified = 0
        var escalatedAt: TimeInterval?
        var t: TimeInterval = 0
        for _ in 0..<8 { // 40s of warning-level swap
            let result = engine.evaluate(input(at: t, swapMB: config.swapWarnMB + 100))
            if result.justEscalated { escalatedAt = t }
            if result.shouldNotify { notified += 1 }
            t += 5
        }
        XCTAssertEqual(engine.level, .warning)
        XCTAssertNotNil(escalatedAt)
        XCTAssertGreaterThanOrEqual(escalatedAt!, config.sustainWarningSeconds)
        XCTAssertEqual(notified, 1)
    }

    func testBriefSpikeDoesNotEscalate() {
        let engine = engine()
        _ = engine.evaluate(input(at: 0, swapMB: config.swapCriticalMB + 100))
        var t: TimeInterval = 5
        for _ in 0..<6 {
            let result = engine.evaluate(input(at: t))
            XCTAssertEqual(result.level, .normal)
            t += 5
        }
    }

    func testCriticalFromPressureAndSwap() {
        let engine = engine()
        var t: TimeInterval = 0
        var final = RiskAssessment.initial
        for _ in 0..<6 { // 30s of critical pressure + big swap
            final = engine.evaluate(input(at: t, pressure: .critical, swapMB: config.swapCriticalMB + 500))
            t += 5
        }
        XCTAssertEqual(final.level, .critical)
    }

    // MARK: - Hysteresis

    func testDeescalationNeedsMarginAndSustain() {
        let engine = engine()

        // Drive to warning.
        var t: TimeInterval = 0
        for _ in 0..<6 {
            _ = engine.evaluate(input(at: t, swapMB: config.swapWarnMB + 100))
            t += 5
        }
        XCTAssertEqual(engine.level, .warning)

        // Score between (warningScore - margin) and warningScore: the engine
        // must stay at warning indefinitely (hysteresis band). Page-outs at
        // 60/s produce severity 0.4, which sits inside the band.
        for _ in 0..<10 {
            _ = engine.evaluate(input(at: t, swapMB: 0, pageoutRate: 60))
            t += 5
        }
        XCTAssertEqual(engine.level, .warning)

        // Fully healthy: de-escalates only after deescalateSeconds.
        var deescalatedAt: TimeInterval?
        for _ in 0..<9 {
            let result = engine.evaluate(input(at: t))
            if result.justDeescalated { deescalatedAt = t }
            t += 5
        }
        XCTAssertEqual(engine.level, .normal)
        guard let at = deescalatedAt else {
            XCTFail("engine never de-escalated from warning")
            return
        }
        XCTAssertGreaterThanOrEqual(at, config.deescalateSeconds)
    }

    func testOscillatingScoreDoesNotEscalate() {
        let engine = engine()
        var t: TimeInterval = 0
        // Alternate between warning-band (0.45) and danger-band (0.6) scores
        // every tick: the pending target keeps resetting, so the engine must
        // never commit an escalation.
        for i in 0..<20 {
            let swap = i % 2 == 0
                ? config.swapWarnMB + 100
                : config.swapCriticalMB + 500
            _ = engine.evaluate(input(at: t, swapMB: swap))
            t += 5
        }
        XCTAssertEqual(engine.level, .normal)
    }

    // MARK: - Notification cooldown

    func testNotificationRespectsCooldown() {
        let engine = engine()
        var t: TimeInterval = 0

        // Escalate to warning.
        for _ in 0..<5 {
            _ = engine.evaluate(input(at: t, swapMB: config.swapWarnMB + 200))
            t += 5
        }
        XCTAssertEqual(engine.level, .warning)

        // Recover fully, then re-trigger warning well within cooldown.
        for _ in 0..<8 { // 40s > deescalateSeconds
            _ = engine.evaluate(input(at: t, swapMB: 0))
            t += 5
        }
        XCTAssertEqual(engine.level, .normal)

        var notifications = 0
        for _ in 0..<5 {
            let result = engine.evaluate(input(at: t, swapMB: config.swapWarnMB + 200))
            if result.shouldNotify { notifications += 1 }
            t += 5
        }
        XCTAssertEqual(engine.level, .warning)
        XCTAssertEqual(notifications, 0, "second warning within cooldown must not re-notify")
    }

    // MARK: - Score combination

    func testMultipleSignalsRaiseScoreAboveAnySingleOne() {
        let engine = engine()
        let single = engine.evaluate(input(at: 0, swapMB: config.swapWarnMB + 100))
        let multi = engine.evaluate(input(
            at: 0,
            swapMB: config.swapWarnMB + 100,
            pageoutRate: 60,
            decompressionRate: 1100))
        XCTAssertGreaterThan(multi.score, single.score)
    }

    func testReasonsContainSignalDescriptions() {
        let engine = engine()
        let result = engine.evaluate(input(at: 0, pressure: .warning, swapMB: config.swapWarnMB + 100))
        XCTAssertTrue(result.reasons.contains { $0.contains("pressure") })
        XCTAssertTrue(result.reasons.contains { $0.contains("Swap") })
        XCTAssertEqual(result.dominantReason, result.reasons.first)
    }
}
