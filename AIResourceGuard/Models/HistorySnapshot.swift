import Foundation

/// A periodic system snapshot persisted in history (kind = "snapshot").
/// Shared by the recorder (MonitorCenter) and readers (incident report,
/// history tab). Encoded as JSON in the event's `detail` column.
///
/// `id` and `timestamp` come from the database row, never the JSON, so
/// rows written by older versions (without those keys) still decode.
struct HistorySnapshot: Identifiable {
    var id: Int64 = 0
    var timestamp = Date()
    let risk: String
    let pressure: String
    let memUsedBytes: UInt64
    let memTotalBytes: UInt64
    let swapUsedBytes: UInt64
    let swapRateBytesPerMin: Double
    let cpuPercent: Double
    let top: [TopEntry]
    let fastestGrowing: String?

    struct TopEntry: Codable {
        let name: String
        let rssBytes: UInt64
        let cpuPercent: Double
        let trendBytesPerMin: Double
    }

    var riskLevel: RiskLevel {
        RiskLevel.parse(risk)
    }
}

extension HistorySnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case risk, pressure, memUsedBytes, memTotalBytes, swapUsedBytes
        case swapRateBytesPerMin, cpuPercent, top, fastestGrowing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        risk = try container.decode(String.self, forKey: .risk)
        pressure = try container.decode(String.self, forKey: .pressure)
        memUsedBytes = try container.decode(UInt64.self, forKey: .memUsedBytes)
        memTotalBytes = try container.decode(UInt64.self, forKey: .memTotalBytes)
        swapUsedBytes = try container.decode(UInt64.self, forKey: .swapUsedBytes)
        swapRateBytesPerMin = try container.decode(Double.self, forKey: .swapRateBytesPerMin)
        cpuPercent = try container.decode(Double.self, forKey: .cpuPercent)
        top = try container.decode([TopEntry].self, forKey: .top)
        fastestGrowing = try container.decodeIfPresent(String.self, forKey: .fastestGrowing)
    }
}
