import Foundation
import SQLite3

struct HistoryEvent: Identifiable, Codable {
    var id: Int64 = 0
    var timestamp: Date = Date()
    /// launch | pressureChange | riskChange | snapshot | action
    var kind: String
    var summary: String
    var detail: String?
}

/// Lightweight local history in SQLite (public C API, WAL mode) on a
/// dedicated utility queue. Pruned to 24h / 1000 rows on write.
final class HistoryStore {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "local.dev.AIResourceGuard.history", qos: .utility)
    private let fileURL: URL

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("AI Resource Guard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("history.sqlite")
        queue.sync { [weak self] in self?.open() }
    }

    private func open() {
        guard sqlite3_open_v2(fileURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 2000)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                summary TEXT NOT NULL,
                detail TEXT
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);")
        prune()
    }

    // MARK: - Public API

    func record(_ event: HistoryEvent) {
        queue.async { [weak self] in self?.insert(event) }
    }

    func recentEvents(limit: Int = 300, completion: @escaping ([HistoryEvent]) -> Void) {
        queue.async { [weak self] in
            let events = self?.fetch(limit: limit) ?? []
            DispatchQueue.main.async { completion(events) }
        }
    }

    func clear() {
        queue.async { [weak self] in self?.exec("DELETE FROM events;") }
    }

    var databasePath: String { fileURL.path }

    // MARK: - Snapshot queries (post-mortem / timeline)

    /// Asynchronously fetches parsed snapshots from the last `hours` hours.
    func fetchSnapshots(hours: TimeInterval, completion: @escaping ([HistorySnapshot]) -> Void) {
        queue.async { [weak self] in
            let cutoff = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
            let snapshots = self?.fetchSnapshotsSync(since: cutoff) ?? []
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    /// Synchronous variant (bounded by the 1000-row cap; safe for tests).
    func snapshotsSync(hours: TimeInterval) -> [HistorySnapshot] {
        let cutoff = Date().addingTimeInterval(-hours * 3600).timeIntervalSince1970
        return queue.sync { [weak self] in self?.fetchSnapshotsSync(since: cutoff) ?? [] }
    }

    /// Most recent snapshot strictly before `date` (used to detect how the
    /// previous session ended).
    func lastSnapshotBefore(_ date: Date) -> HistorySnapshot? {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                    SELECT id, ts, detail FROM events
                    WHERE kind = 'snapshot' AND ts < ?
                    ORDER BY ts DESC LIMIT 1;
                    """, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.parseSnapshot(
                id: sqlite3_column_int64(statement, 0),
                timestamp: sqlite3_column_double(statement, 1),
                detail: sqlite3_column_text(statement, 2))
        }
    }

    /// Blocks until queued writes have been applied (test helper).
    func waitForPendingWrites() {
        queue.sync {}
    }

    private func fetchSnapshotsSync(since cutoff: TimeInterval) -> [HistorySnapshot] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
                SELECT id, ts, detail FROM events
                WHERE kind = 'snapshot' AND ts >= ?
                ORDER BY ts ASC;
                """, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        var snapshots: [HistorySnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let snapshot = Self.parseSnapshot(
                id: sqlite3_column_int64(statement, 0),
                timestamp: sqlite3_column_double(statement, 1),
                detail: sqlite3_column_text(statement, 2)) {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    private static func parseSnapshot(id: Int64,
                                      timestamp: TimeInterval,
                                      detail: UnsafePointer<UInt8>?) -> HistorySnapshot? {
        guard let detail else { return nil }
        let bytes = UnsafeBufferPointer(start: detail, count: Int(strlen(detail)))
        guard let data = String(bytes: bytes, encoding: .utf8)?.data(using: .utf8),
              var snapshot = try? JSONDecoder().decode(HistorySnapshot.self, from: data) else {
            return nil
        }
        // Row id / ts are authoritative.
        snapshot.id = id
        snapshot.timestamp = Date(timeIntervalSince1970: timestamp)
        return snapshot
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) {
        guard let db else { return }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            if let error { sqlite3_free(error) }
            return
        }
    }

    private func insert(_ event: HistoryEvent) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
                INSERT INTO events (ts, kind, summary, detail) VALUES (?, ?, ?, ?);
                """, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, event.kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, event.summary, -1, SQLITE_TRANSIENT)
        if let detail = event.detail {
            sqlite3_bind_text(statement, 4, detail, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { return }
        prune()
    }

    private func fetch(limit: Int) -> [HistoryEvent] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
                SELECT id, ts, kind, summary, detail FROM events ORDER BY id DESC LIMIT ?;
                """, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var events: [HistoryEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let detail = sqlite3_column_text(statement, 4)
            events.append(HistoryEvent(
                id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: String(cString: sqlite3_column_text(statement, 2)),
                summary: String(cString: sqlite3_column_text(statement, 3)),
                detail: detail == nil ? nil : String(cString: detail!)))
        }
        return events
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        exec("DELETE FROM events WHERE ts < \(cutoff);")
        exec("""
            DELETE FROM events WHERE id NOT IN
                (SELECT id FROM events ORDER BY id DESC LIMIT 1000);
            """)
    }
}
