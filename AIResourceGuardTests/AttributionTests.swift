import XCTest
@testable import AIResourceGuard

// MARK: - AttributionEngine

final class AttributionEngineTests: XCTestCase {

    private func group(_ name: String, footprintMB: Double, growthMBPerMin: Double = 0,
                       isApp: Bool = true, stale: Bool = false, uid: Int32 = 501) -> ProcessGroupInfo {
        ProcessGroupInfo(
            key: isApp ? "app:\(name)" : "exe:\(name)",
            displayName: name,
            isApp: isApp,
            iconPath: nil,
            totalRSS: UInt64(footprintMB * 1_048_576),
            totalFootprint: UInt64(footprintMB * 1_048_576),
            cpuFraction: 0,
            processes: [ProcessRecord(
                pid: 1, ppid: 0, name: name, path: "/Applications/\(name).app/Contents/MacOS/\(name)",
                rssBytes: UInt64(footprintMB * 1_048_576),
                footprintBytes: UInt64(footprintMB * 1_048_576),
                cpuFraction: 0, euid: uid, isStopped: false, isMCP: false,
                startSeconds: 0, groupKey: "app:\(name)", groupDisplayName: name)],
            trendBytesPerMin: 0,
            footprintTrendBytesPerMin: growthMBPerMin * 1_048_576,
            isStaleWorkload: stale,
            ageSeconds: stale ? 5400 : 0)
    }

    private func sample(usedGB: Double, pageout: Double = 0, decomp: Double = 0) -> SystemSample {
        SystemSample(timestamp: Date(), pressure: .normal,
                     physicalTotalBytes: 17_179_869_184,
                     usedBytes: UInt64(usedGB * 1_073_741_824),
                     cachedBytes: 0, compressedBytes: 0, freeBytes: 0,
                     swapUsedBytes: 10 * 1_073_741_824, swapTotalBytes: 0,
                     swapRateBytesPerMin: 0, pageinRate: 0, pageoutRate: pageout,
                     decompressionRate: decomp, compressionRate: 0, cpuUsage: 0)
    }

    /// The exact regression scenario: system Critical (13.4 GB used) but no
    /// process is big or growing — the list must still show the biggest
    /// consumers, flagged as "no single source found".
    func testCriticalNeverEmptyWithoutClearSource() {
        let baseline = BaselineTracker() // no group baselines → no deviators
        let groups = [
            group("Safari", footprintMB: 280),
            group("Lark", footprintMB: 240),
            group("Notes", footprintMB: 90),
            group("Music", footprintMB: 120),
        ]
        let stats = ScanStats(totalPids: 320, rusageReads: 300)
        let selection = AttributionEngine.analyze(
            level: .critical, sample: sample(usedGB: 13.4),
            groups: groups, baseline: baseline, scanStats: stats)

        XCTAssertFalse(selection.apps.isEmpty, "Critical must never render an empty list")
        XCTAssertTrue(selection.fallbackOnly)
        XCTAssertFalse(selection.hasClearSource)
        XCTAssertEqual(selection.apps.count, 4)
        XCTAssertEqual(selection.apps.first?.displayName, "Safari", "ordered by footprint")
    }

    func testAttributionIncompleteWhenCoverageLow() {
        let baseline = BaselineTracker()
        // Visible apps only account for ~1.5 GB of 13 GB used memory.
        let groups = [group("Safari", footprintMB: 800), group("Notes", footprintMB: 700)]
        let stats = ScanStats(totalPids: 300, rusageReads: 120) // 60% invisible
        let selection = AttributionEngine.analyze(
            level: .critical, sample: sample(usedGB: 13),
            groups: groups, baseline: baseline, scanStats: stats)

        XCTAssertTrue(selection.attributionIncomplete)
        XCTAssertEqual(selection.source, .incompleteAttribution)
    }

    func testNormalShowsOnlyTrueRiskSources() {
        let baseline = BaselineTracker()
        let groups = [
            group("Chrome", footprintMB: 4000),        // big but stable
            group("Simulator", footprintMB: 600, growthMBPerMin: 120), // growing
        ]
        let selection = AttributionEngine.analyze(
            level: .normal, sample: sample(usedGB: 10),
            groups: groups, baseline: baseline, scanStats: nil)

        XCTAssertEqual(selection.apps.map(\.displayName), ["Simulator"])
        XCTAssertFalse(selection.fallbackOnly)
        XCTAssertEqual(selection.source, .none)
    }

    func testSingleRunawayClassification() {
        let baseline = BaselineTracker()
        let groups = [
            group("IntelliJ IDEA", footprintMB: 2600, growthMBPerMin: 500),
            group("Chrome", footprintMB: 3000, growthMBPerMin: 40),
        ]
        let selection = AttributionEngine.analyze(
            level: .danger, sample: sample(usedGB: 13),
            groups: groups, baseline: baseline, scanStats: nil)

        XCTAssertEqual(selection.source, .singleRunaway(name: "IntelliJ IDEA"))
        XCTAssertEqual(selection.apps.first?.displayName, "IntelliJ IDEA")
    }

    func testBuildBurstClassification() {
        let baseline = BaselineTracker()
        let groups = [
            group("swift-frontend", footprintMB: 2200, growthMBPerMin: 400, isApp: false),
            group("Chrome", footprintMB: 3000, growthMBPerMin: 30),
        ]
        let selection = AttributionEngine.analyze(
            level: .danger, sample: sample(usedGB: 13.5),
            groups: groups, baseline: baseline, scanStats: nil)
        XCTAssertEqual(selection.source, .buildBurst)
    }

    func testLegacyAccumulationClassification() {
        let baseline = BaselineTracker()
        let groups = [
            group("node", footprintMB: 1500, isApp: false, stale: true, uid: 501),
            group("gradle", footprintMB: 900, isApp: false, stale: true),
            group("Chrome", footprintMB: 1500),
        ]
        let selection = AttributionEngine.analyze(
            level: .danger, sample: sample(usedGB: 13),
            groups: groups, baseline: baseline, scanStats: nil)
        XCTAssertEqual(selection.source, .legacyAccumulation)
    }

    func testBaselineDeviationOutranksStableHeavies() {
        let baseline = BaselineTracker()
        // Chrome's learned normal is 500 MB; it is now at 2.5 GB.
        for _ in 0..<70 { baseline.recordNormalGroups([group("Chrome", footprintMB: 500)]) }
        let groups = [
            group("Stable Big App", footprintMB: 4000),
            group("Chrome", footprintMB: 2500),
        ]
        let selection = AttributionEngine.analyze(
            level: .warning, sample: sample(usedGB: 12),
            groups: groups, baseline: baseline, scanStats: nil)

        XCTAssertTrue(selection.hasClearSource)
        XCTAssertEqual(selection.apps.first?.displayName, "Chrome",
                       "a group far above its own history must outrank a bigger stable one")
    }
}

// MARK: - EpisodeBuilder

final class EpisodeBuilderTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func snap(minutes: Double, risk: String, swapGB: Double,
                      top: [(String, Double)] = []) -> HistorySnapshot {
        HistorySnapshot(id: 0, timestamp: t0.addingTimeInterval(minutes * 60), risk: risk,
                        pressure: "正常", memUsedBytes: 11_000_000_000, memTotalBytes: 17_179_869_184,
                        swapUsedBytes: UInt64(swapGB * 1_073_741_824),
                        swapRateBytesPerMin: 200 * 1_048_576, cpuPercent: 5,
                        top: top.map {
                            HistorySnapshot.TopEntry(
                                name: $0.0, rssBytes: UInt64($0.1 * 1_073_741_824),
                                cpuPercent: 1, trendBytesPerMin: 0,
                                footprintBytes: UInt64($0.1 * 1_073_741_824))
                        },
                        fastestGrowing: top.first?.0)
    }

    func testBuildsEpisodesWithPeaksSuspectsAndActions() {
        let snapshots = [
            snap(minutes: 0, risk: "正常", swapGB: 8, top: [("IDEA", 1.0)]),
            snap(minutes: 5, risk: "注意", swapGB: 9, top: [("IDEA", 1.6)]),
            snap(minutes: 10, risk: "压力较高", swapGB: 11.5, top: [("IDEA", 2.4)]),
            snap(minutes: 15, risk: "注意", swapGB: 11, top: [("IDEA", 2.5)]),
            snap(minutes: 20, risk: "正常", swapGB: 9.5),
            snap(minutes: 40, risk: "正常", swapGB: 9),
        ]
        let events = [
            HistoryEvent(id: 1, timestamp: t0.addingTimeInterval(12 * 60), kind: "action",
                         summary: "[自动]暂停 IntelliJ IDEA：20 个进程已发送 SIGSTOP", detail: nil),
            HistoryEvent(id: 2, timestamp: t0.addingTimeInterval(50 * 60), kind: "action",
                         summary: "[自动]暂停 无关：1 个进程已发送 SIGSTOP", detail: nil), // outside
        ]
        let episodes = EpisodeBuilder.build(snapshots: snapshots, events: events)

        XCTAssertEqual(episodes.count, 1)
        let episode = episodes[0]
        XCTAssertEqual(episode.peakRisk, .danger)
        XCTAssertEqual(episode.peakSwapBytes, UInt64(11.5 * 1_073_741_824))
        XCTAssertEqual(episode.primarySuspect?.name, "IDEA")
        XCTAssertEqual(episode.actions.count, 1, "actions outside the window are excluded")
        XCTAssertNotNil(episode.endedAt)
        XCTAssertEqual(episode.startedAt, snapshots[1].timestamp)
    }

    func testOngoingEpisodeHasNoEnd() {
        let snapshots = [
            snap(minutes: 0, risk: "正常", swapGB: 8),
            snap(minutes: 5, risk: "注意", swapGB: 9),
            snap(minutes: 10, risk: "压力较高", swapGB: 10),
        ]
        let episodes = EpisodeBuilder.build(snapshots: snapshots, events: [])
        XCTAssertEqual(episodes.count, 1)
        XCTAssertNil(episodes[0].endedAt)
    }
}
