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
        /// Physical footprint (0 in rows written before footprint tracking).
        var footprintBytes: UInt64 = 0
        /// Stable group key (empty in rows written before stable keys).
        var groupKey: String = ""

        enum CodingKeys: String, CodingKey {
            case name, rssBytes, cpuPercent, trendBytesPerMin, footprintBytes, groupKey
        }

        init(name: String, rssBytes: UInt64, cpuPercent: Double,
             trendBytesPerMin: Double, footprintBytes: UInt64 = 0,
             groupKey: String = "") {
            self.name = name
            self.rssBytes = rssBytes
            self.cpuPercent = cpuPercent
            self.trendBytesPerMin = trendBytesPerMin
            self.footprintBytes = footprintBytes
            self.groupKey = groupKey
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            rssBytes = try c.decode(UInt64.self, forKey: .rssBytes)
            cpuPercent = try c.decode(Double.self, forKey: .cpuPercent)
            trendBytesPerMin = try c.decode(Double.self, forKey: .trendBytesPerMin)
            footprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .footprintBytes) ?? 0
            groupKey = try c.decodeIfPresent(String.self, forKey: .groupKey) ?? ""
        }
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
