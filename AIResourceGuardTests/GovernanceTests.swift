import XCTest
@testable import AIResourceGuard

// MARK: - Baseline

final class BaselineTrackerTests: XCTestCase {
    func testStatsConvergeAndReportDeviation() {
        let tracker = BaselineTracker()
        // 100 normal samples around 6 GB swap.
        for _ in 0..<100 {
            tracker.recordNormalSystem(sample: SystemSample(
                timestamp: Date(), pressure: .normal,
                physicalTotalBytes: 17_179_869_184,
                usedBytes: 10_000_000_000, cachedBytes: 0, compressedBytes: 0, freeBytes: 0,
                swapUsedBytes: 6 * 1_073_741_824, swapTotalBytes: 0,
                swapRateBytesPerMin: 0, pageinRate: 0, pageoutRate: 2, decompressionRate: 100,
                compressionRate: 0, cpuUsage: 0))
        }
        XCTAssertTrue(tracker.swapUsedMB.isReady)

        let context = tracker.context(sample: sample(swapMB: 12 * 1024, pageout: 2, decomp: 100),
                                       groups: [])
        XCTAssertTrue(context.ready)
        XCTAssertGreaterThan(context.swapMeanMB, 5000)
        XCTAssertLessThan(context.swapMeanMB, 7000)
    }

    func testGroupBaselineDetectsDeviation() {
        let tracker = BaselineTracker()
        for _ in 0..<80 {
            tracker.recordNormalGroups([group(name: "ZCode", rssMB: 500)])
        }
        // Same group suddenly tripled.
        let context = tracker.context(sample: sample(swapMB: 0, pageout: 0, decomp: 0),
                                       groups: [group(name: "ZCode", rssMB: 2400)])
        XCTAssertEqual(context.deviatingGroups.count, 1)
        XCTAssertEqual(context.deviatingGroups.first?.name, "ZCode")
        XCTAssertEqual(tracker.groupMeanFootprintMB(groupKey: "exe:ZCode") ?? 0, 500, accuracy: 50)
    }

    func testBootstrapIgnoresAbnormalSnapshots() {
        let tracker = BaselineTracker()
        var snapshots: [HistorySnapshot] = []
        for i in 0..<40 {
            snapshots.append(snapshot(risk: "正常", swapMB: Double(3000 + i % 5), name: "ZCode", rssMB: 400))
        }
        snapshots.append(snapshot(risk: "即将失控", swapMB: 12000, name: "ZCode", rssMB: 5000))
        tracker.bootstrap(from: snapshots)
        // The critical snapshot must not pollute the baseline.
        XCTAssertLessThan(tracker.swapUsedMB.mean, 3200)
    }

    // MARK: - Fixtures

    private func sample(swapMB: Double, pageout: Double, decomp: Double) -> SystemSample {
        SystemSample(timestamp: Date(), pressure: .normal,
                     physicalTotalBytes: 17_179_869_184,
                     usedBytes: 0, cachedBytes: 0, compressedBytes: 0, freeBytes: 0,
                     swapUsedBytes: UInt64(swapMB * 1_048_576), swapTotalBytes: 0,
                     swapRateBytesPerMin: 0, pageinRate: 0, pageoutRate: pageout,
                     decompressionRate: decomp, compressionRate: 0, cpuUsage: 0)
    }

    private func group(name: String, rssMB: Double) -> ProcessGroupInfo {
        ProcessGroupInfo(key: "exe:\(name)", displayName: name, isApp: false, iconPath: nil,
                         totalRSS: UInt64(rssMB * 1_048_576),
                         totalFootprint: UInt64(rssMB * 1_048_576), cpuFraction: 0,
                         processes: [], trendBytesPerMin: 0,
                         isStaleWorkload: false, ageSeconds: 0)
    }

    private func snapshot(risk: String, swapMB: Double, name: String, rssMB: Double) -> HistorySnapshot {
        HistorySnapshot(id: 0, timestamp: Date(), risk: risk, pressure: "正常",
                        memUsedBytes: 0, memTotalBytes: 17_179_869_184,
                        swapUsedBytes: UInt64(swapMB * 1_048_576), swapRateBytesPerMin: 0,
                        cpuPercent: 0,
                        top: [.init(name: name, rssBytes: UInt64(rssMB * 1_048_576),
                                    cpuPercent: 0, trendBytesPerMin: 0)],
                        fastestGrowing: nil)
    }
}

// MARK: - Rescue score

final class RescueScorerTests: XCTestCase {
    private func group(name: String, rssMB: Double, trendMBPerMin: Double = 0,
                       isApp: Bool = true, stale: Bool = false) -> ProcessGroupInfo {
        ProcessGroupInfo(key: isApp ? "app:\(name)" : "exe:\(name)", displayName: name,
                         isApp: isApp, iconPath: nil,
                         totalRSS: UInt64(rssMB * 1_048_576),
                         totalFootprint: UInt64(rssMB * 1_048_576), cpuFraction: 0,
                         processes: [],
                         trendBytesPerMin: 0,
                         footprintTrendBytesPerMin: trendMBPerMin * 1_048_576,
                         isStaleWorkload: stale, ageSeconds: stale ? 5400 : 0)
    }

    func testForegroundAppIsStronglyProtected() {
        let background = group(name: "node 构建任务", rssMB: 1200, isApp: false)
        let foreground = group(name: "Chrome", rssMB: 4000)
        let backgroundScore = RescueScorer.score(group: background, isForeground: false, baselineMeanFootprintMB: nil)
        let foregroundScore = RescueScorer.score(group: foreground, isForeground: true, baselineMeanFootprintMB: nil)
        XCTAssertGreaterThan(backgroundScore, foregroundScore)
    }

    func testStaleWorkloadBeatsEquallySizedStableApp() {
        let stale = group(name: "gradle", rssMB: 2000, isApp: false, stale: true)
        let stable = group(name: "Lark", rssMB: 2000)
        XCTAssertGreaterThan(
            RescueScorer.score(group: stale, isForeground: false, baselineMeanFootprintMB: nil),
            RescueScorer.score(group: stable, isForeground: false, baselineMeanFootprintMB: nil))
    }

    func testGrowthAndBaselineDeviationAddScore() {
        let plain = group(name: "A", rssMB: 2000)
        let growing = group(name: "B", rssMB: 2000, trendMBPerMin: 300)
        let aboveBaseline = group(name: "C", rssMB: 2000)
        let base = RescueScorer.score(group: plain, isForeground: false, baselineMeanFootprintMB: nil)
        XCTAssertGreaterThan(
            RescueScorer.score(group: growing, isForeground: false, baselineMeanFootprintMB: nil), base)
        XCTAssertGreaterThan(
            RescueScorer.score(group: aboveBaseline, isForeground: false, baselineMeanFootprintMB: 300), base)
    }
}

// MARK: - Staged recovery

final class RecoveryPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func state(level: RiskLevel,
                       at seconds: TimeInterval,
                       paused: Int,
                       stableSince: TimeInterval? = nil,
                       nextResumeAt: TimeInterval? = nil,
                       lastResumedAt: TimeInterval? = nil,
                       justFromDanger: Bool = false) -> RecoveryState {
        RecoveryState(level: level, now: t0.addingTimeInterval(seconds),
                      pausedTaskCount: paused,
                      stableSince: stableSince.map { t0.addingTimeInterval($0) },
                      nextResumeAt: nextResumeAt.map { t0.addingTimeInterval($0) },
                      lastResumedAt: lastResumedAt.map { t0.addingTimeInterval($0) },
                      justDeescalatedFromDanger: justFromDanger)
    }

    func testWaitsForStableWindowBeforeFirstResume() {
        // System just returned to normal with 3 paused tasks.
        XCTAssertEqual(RecoveryPlanner.decide(state(level: .normal, at: 0, paused: 3),
                                              windowSeconds: 60, observeSeconds: 45),
                       .startWindow)
        // Still inside the window.
        XCTAssertEqual(RecoveryPlanner.decide(state(level: .normal, at: 30, paused: 3, stableSince: 0),
                                              windowSeconds: 60, observeSeconds: 45),
                       .none)
        // Window elapsed → first resume.
        XCTAssertEqual(RecoveryPlanner.decide(state(level: .normal, at: 61, paused: 3, stableSince: 0),
                                              windowSeconds: 60, observeSeconds: 45),
                       .resumeNext)
    }

    func testObservationGapBetweenResumes() {
        // Second resume must wait out the observation interval
        // (first resume at t=61 → next eligible at t=106).
        XCTAssertEqual(RecoveryPlanner.decide(
            state(level: .normal, at: 100, paused: 2, stableSince: 0, nextResumeAt: 106),
            windowSeconds: 60, observeSeconds: 45), .none)
        XCTAssertEqual(RecoveryPlanner.decide(
            state(level: .normal, at: 107, paused: 2, stableSince: 0, nextResumeAt: 106),
            windowSeconds: 60, observeSeconds: 45), .resumeNext)
    }

    func testDegradationDuringObservationRepausesLast() {
        XCTAssertEqual(RecoveryPlanner.decide(
            state(level: .warning, at: 200, paused: 1, lastResumedAt: 180),
            windowSeconds: 60, observeSeconds: 45), .repauseLast)
        // After the observation window the resume is accepted; degradation
        // no longer takes it back.
        XCTAssertEqual(RecoveryPlanner.decide(
            state(level: .warning, at: 300, paused: 0, lastResumedAt: 180),
            windowSeconds: 60, observeSeconds: 45), .none)
    }

    func testFinalAnnounceWaitsForLastObservation() {
        // Last task resumed 10s ago — not yet safe to declare recovery.
        XCTAssertEqual(RecoveryPlanner.decide(
            state(level: .normal, at: 190, paused: 0, lastResumedAt: 180),
            windowSeconds: 60, observeSeconds: 45), .none)
        XCTAssertEqual(RecoveryPlanner.decide(
            state(level: .normal, at: 230, paused: 0, lastResumedAt: 180),
            windowSeconds: 60, observeSeconds: 45), .announceAllRecovered)
    }
}

// MARK: - Incident summary

final class IncidentSummarizerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func snap(minutes: Double, risk: String, swapGB: Double,
                      top: [(String, Double)] = []) -> HistorySnapshot {
        HistorySnapshot(id: 0, timestamp: t0.addingTimeInterval(minutes * 60), risk: risk,
                        pressure: "正常", memUsedBytes: 11_000_000_000, memTotalBytes: 17_179_869_184,
                        swapUsedBytes: UInt64(swapGB * 1_073_741_824),
                        swapRateBytesPerMin: 200 * 1_048_576, cpuPercent: 5,
                        top: top.map { HistorySnapshot.TopEntry(
                            name: $0.0, rssBytes: UInt64($0.1 * 1_073_741_824),
                            cpuPercent: 1, trendBytesPerMin: 0) },
                        fastestGrowing: top.first?.0)
    }

    func testSummaryDescribesEpisode() {
        let snapshots = [
            snap(minutes: 0, risk: "正常", swapGB: 8, top: [("IntelliJ IDEA", 1.0)]),
            snap(minutes: 5, risk: "正常", swapGB: 8, top: [("IntelliJ IDEA", 1.1)]),
            snap(minutes: 10, risk: "注意", swapGB: 9, top: [("IntelliJ IDEA", 1.6)]),
            snap(minutes: 15, risk: "压力较高", swapGB: 11, top: [("IntelliJ IDEA", 2.4)]),
            snap(minutes: 20, risk: "压力较高", swapGB: 12.5, top: [("IntelliJ IDEA", 2.6)]),
            snap(minutes: 25, risk: "正常", swapGB: 10, top: [("IntelliJ IDEA", 2.2)]),
        ]
        let events = [
            HistoryEvent(id: 1, timestamp: t0.addingTimeInterval(14 * 60), kind: "action",
                         summary: "[自动]暂停 IntelliJ IDEA：20 个进程已发送 SIGSTOP", detail: nil),
        ]
        let lines = IncidentSummarizer.summarize(snapshots: snapshots, events: events)

        XCTAssertTrue(lines.contains { $0.contains("起风险升至") })
        XCTAssertTrue(lines.contains { $0.contains("恢复正常") })
        XCTAssertTrue(lines.contains { $0.contains("IntelliJ IDEA") })
        XCTAssertTrue(lines.contains { $0.contains("暂停") })
        XCTAssertTrue(lines.last?.contains("最可能原因") == true)
    }

    func testNoEpisodeReturnsCalmLine() {
        let snapshots = [
            snap(minutes: 0, risk: "正常", swapGB: 8),
            snap(minutes: 5, risk: "正常", swapGB: 8),
        ]
        let lines = IncidentSummarizer.summarize(snapshots: snapshots, events: [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("正常"))
    }
}

// MARK: - RiskEngine × baseline

final class RiskEngineBaselineTests: XCTestCase {
    func testBaselineSwapDeviationEscalates() {
        let config = ThresholdConfig()
        let engine = RiskEngine(thresholdsProvider: { config })

        // Baseline: swap normal ≈ 3 GB; current 8 GB with all other signals quiet.
        var baseline = BaselineContext()
        baseline.ready = true
        baseline.swapMeanMB = 3072
        baseline.swapStdMB = 200

        var t: TimeInterval = 0
        var last = RiskAssessment.initial
        for _ in 0..<8 { // 40s sustained
            var input = RiskInput(timestamp: Date(timeIntervalSinceReferenceDate: t),
                                  swapUsedBytes: 8 * 1024 * 1_048_576)
            input.baseline = baseline
            last = engine.evaluate(input)
            t += 5
        }
        // 8 GB against a 3 GB baseline must escalate even though the fixed
        // danger threshold (5 GB) alone would only reach 压力较高.
        XCTAssertGreaterThanOrEqual(last.level, .warning)
        XCTAssertTrue(last.reasons.contains { $0.contains("常态") })
    }

    func testNoBaselineFallsBackToFixedThresholds() {
        let config = ThresholdConfig()
        let engine = RiskEngine(thresholdsProvider: { config })
        let result = engine.evaluate(RiskInput(
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            swapUsedBytes: UInt64(1500 * 1_048_576))) // below every fixed threshold
        XCTAssertEqual(result.level, .normal)
        XCTAssertEqual(result.headline, "系统正常，无需处理")
    }
}
