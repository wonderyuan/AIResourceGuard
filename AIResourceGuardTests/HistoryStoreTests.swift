import XCTest
@testable import AIResourceGuard

final class HistoryStoreTests: XCTestCase {
    private var store: HistoryStore?

    override func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-test-\(UUID().uuidString).sqlite")
        store = HistoryStore(fileURL: url)
    }

    private func snapshot(at date: Date, risk: String = "Warning",
                          swap: UInt64 = 2_000_000_000,
                          top: [HistorySnapshot.TopEntry] = []) -> HistorySnapshot {
        HistorySnapshot(
            id: 0, timestamp: date, risk: risk, pressure: "Normal",
            memUsedBytes: 10_000_000_000, memTotalBytes: 17_179_869_184,
            swapUsedBytes: swap, swapRateBytesPerMin: 0, cpuPercent: 3,
            top: top, fastestGrowing: top.first?.name)
    }

    private func record(_ snap: HistorySnapshot) {
        let encoded = (try? JSONEncoder().encode(snap))
            .flatMap { String(data: $0, encoding: .utf8) }
        store?.record(HistoryEvent(
            kind: "snapshot",
            summary: "test snapshot",
            detail: encoded))
    }

    func testSnapshotRoundTrip() {
        let now = Date()
        record(snapshot(at: now.addingTimeInterval(-120),
                        top: [.init(name: "Cursor", rssBytes: 5_000_000_000,
                                    cpuPercent: 12, trendBytesPerMin: 300_000_000)]))
        record(snapshot(at: now.addingTimeInterval(-60), risk: "Critical", swap: 6_000_000_000))
        record(snapshot(at: now, risk: "Danger", swap: 4_000_000_000))
        store?.waitForPendingWrites()

        let fetched = store!.snapshotsSync(hours: 1)
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(fetched.first?.riskLevel, .warning)
        XCTAssertEqual(fetched.last?.riskLevel, .danger)
        XCTAssertEqual(fetched.first?.top.first?.name, "Cursor")
        XCTAssertEqual(fetched.first?.top.first?.rssBytes, 5_000_000_000)
        XCTAssertEqual(fetched.last?.swapUsedBytes, 4_000_000_000)
    }

    func testLastSnapshotBeforeIgnoresOtherKinds() {
        let now = Date()
        record(snapshot(at: now.addingTimeInterval(-30), risk: "Critical"))
        store?.record(HistoryEvent(kind: "launch", summary: "relaunched"))
        store?.waitForPendingWrites()

        // The launch event must not shadow the snapshot.
        let last = store!.lastSnapshotBefore(now.addingTimeInterval(1))
        XCTAssertEqual(last?.riskLevel, .critical)
        XCTAssertNil(store!.lastSnapshotBefore(now.addingTimeInterval(-100)))
    }

    func testMalformedDetailIsSkipped() {
        store?.record(HistoryEvent(kind: "snapshot", summary: "broken", detail: "not json"))
        store?.record(HistoryEvent(kind: "snapshot", summary: "no detail", detail: nil))
        record(snapshot(at: Date()))
        store?.waitForPendingWrites()

        XCTAssertEqual(store!.snapshotsSync(hours: 1).count, 1)
    }

    /// Rows written by v1.0 lack `id`/`timestamp` in the JSON — they must
    /// still decode (row columns are authoritative).
    func testDecodesLegacyDetailWithoutIdAndTimestamp() {
        let legacyJSON = """
        {"risk":"Danger","pressure":"Normal","memUsedBytes":13000000000,"memTotalBytes":17179869184,"swapUsedBytes":9000000000,"swapRateBytesPerMin":0,"cpuPercent":2,"top":[{"name":"node","rssBytes":3000000000,"cpuPercent":5,"trendBytesPerMin":0}],"fastestGrowing":"node"}
        """
        store?.record(HistoryEvent(kind: "snapshot", summary: "legacy", detail: legacyJSON))
        store?.waitForPendingWrites()

        let fetched = store!.snapshotsSync(hours: 1)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.riskLevel, .danger)
        XCTAssertEqual(fetched.first?.top.first?.name, "node")
        XCTAssertEqual(fetched.first!.timestamp.timeIntervalSince1970,
                       Date().timeIntervalSince1970, accuracy: 60)
    }
}
