import Foundation

// MARK: - Levels

enum PressureLevel: Int, Codable, Comparable {
    case normal = 0
    case warning = 1
    case critical = 2

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }

    static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum RiskLevel: Int, Codable, CaseIterable, Comparable {
    case normal = 0
    case warning = 1
    case danger = 2
    case critical = 3

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .danger: return "Danger"
        case .critical: return "Critical"
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - System sample

/// One tick of system-wide metrics. All byte counts are absolute; rates are
/// computed by the monitor against the previous tick.
struct SystemSample {
    let timestamp: Date
    let pressure: PressureLevel
    let physicalTotalBytes: UInt64
    /// wire + active + compressor pages (approximates Activity Monitor "used").
    let usedBytes: UInt64
    /// inactive + speculative pages (approximates "cached").
    let cachedBytes: UInt64
    /// compressor_page_count × page size.
    let compressedBytes: UInt64
    let freeBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    /// Sliding-window (≈60s) swap growth, bytes per minute.
    let swapRateBytesPerMin: Double
    let pageinRate: Double
    let pageoutRate: Double
    let decompressionRate: Double
    let compressionRate: Double
    /// Total system CPU usage, 0...1.
    let cpuUsage: Double

    var usedFraction: Double {
        physicalTotalBytes == 0 ? 0 : Double(usedBytes) / Double(physicalTotalBytes)
    }
}

// MARK: - Processes

struct ProcessRecord {
    let pid: Int32
    let ppid: Int32
    let name: String
    let path: String
    let rssBytes: UInt64
    let footprintBytes: UInt64
    /// 0...1 of one core (can exceed 1 for multithreaded work).
    let cpuFraction: Double
    let euid: Int32
    let isStopped: Bool
    let groupKey: String
    let groupDisplayName: String
}

enum TrendDirection {
    case up, down, flat

    var symbol: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .flat: return "arrow.right"
        }
    }
}

struct ProcessGroupInfo: Identifiable {
    let key: String
    let displayName: String
    let isApp: Bool
    let iconPath: String?
    let totalRSS: UInt64
    let totalFootprint: UInt64
    let cpuFraction: Double
    let processes: [ProcessRecord]
    /// Bytes per minute across a ~5-minute window (0 when window is too short).
    let trendBytesPerMin: Double

    var id: String { key }

    var trendDirection: TrendDirection {
        let mb = trendBytesPerMin / 1_048_576
        if mb > 50 { return .up }
        if mb < -50 { return .down }
        return .flat
    }

    var anyStopped: Bool { processes.contains(where: \.isStopped) }
}

// MARK: - Risk engine I/O

struct RiskInput {
    var timestamp = Date()
    var pressure: PressureLevel = .normal
    var memoryUsedFraction: Double = 0
    var swapUsedBytes: UInt64 = 0
    var swapRateBytesPerMin: Double = 0
    var pageoutRate: Double = 0
    var decompressionRate: Double = 0
    var topGrowthBytesPerMin: Double = 0
    var topGrowthGroup: String?
}

struct RiskAssessment {
    let level: RiskLevel
    let previousLevel: RiskLevel
    let score: Double
    let reasons: [String]
    let dominantReason: String?
    let justEscalated: Bool
    let justDeescalated: Bool
    let shouldNotify: Bool

    static let initial = RiskAssessment(
        level: .normal, previousLevel: .normal, score: 0,
        reasons: [], dominantReason: nil,
        justEscalated: false, justDeescalated: false, shouldNotify: false)
}

// MARK: - Formatting

func fmtBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

func fmtRate(_ bytesPerMin: Double) -> String {
    let mb = bytesPerMin / 1_048_576
    if abs(mb) >= 1024 {
        return String(format: "%+.1f GB/min", mb / 1024)
    }
    return String(format: "%+.0f MB/min", mb)
}

func fmtMB(_ mb: Double) -> String {
    mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}
