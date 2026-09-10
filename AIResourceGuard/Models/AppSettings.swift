import Foundation

// MARK: - Thresholds

struct ThresholdConfig: Codable, Equatable {
    var warningScore = 0.35
    var dangerScore = 0.60
    var criticalScore = 0.85
    var deescalationMargin = 0.12
    var sustainWarningSeconds: Double = 12
    var sustainDangerSeconds: Double = 10
    var sustainCriticalSeconds: Double = 6
    var deescalateSeconds: Double = 30
    var notifyCooldownSeconds: Double = 120
    var swapWarnMB: Double = 2048
    var swapDangerMB: Double = 5120
    var swapCriticalMB: Double = 9216
    var swapRateWarnMBPerMin: Double = 150
    var swapRateDangerMBPerMin: Double = 400
    var swapRateCriticalMBPerMin: Double = 800
    /// Staged recovery: how long the system must stay 正常 before the first
    /// paused task is resumed, and how long it must stay stable between
    /// consecutive resumes.
    var recoveryWindowSeconds: Double = 60
    var recoveryObserveSeconds: Double = 45

    // Fields added after v1 default to their current values when decoding
    // settings persisted by an older build.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warningScore = try c.decodeIfPresent(Double.self, forKey: .warningScore) ?? 0.35
        dangerScore = try c.decodeIfPresent(Double.self, forKey: .dangerScore) ?? 0.60
        criticalScore = try c.decodeIfPresent(Double.self, forKey: .criticalScore) ?? 0.85
        deescalationMargin = try c.decodeIfPresent(Double.self, forKey: .deescalationMargin) ?? 0.12
        sustainWarningSeconds = try c.decodeIfPresent(Double.self, forKey: .sustainWarningSeconds) ?? 12
        sustainDangerSeconds = try c.decodeIfPresent(Double.self, forKey: .sustainDangerSeconds) ?? 10
        sustainCriticalSeconds = try c.decodeIfPresent(Double.self, forKey: .sustainCriticalSeconds) ?? 6
        deescalateSeconds = try c.decodeIfPresent(Double.self, forKey: .deescalateSeconds) ?? 30
        notifyCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .notifyCooldownSeconds) ?? 120
        swapWarnMB = try c.decodeIfPresent(Double.self, forKey: .swapWarnMB) ?? 2048
        swapDangerMB = try c.decodeIfPresent(Double.self, forKey: .swapDangerMB) ?? 5120
        swapCriticalMB = try c.decodeIfPresent(Double.self, forKey: .swapCriticalMB) ?? 9216
        swapRateWarnMBPerMin = try c.decodeIfPresent(Double.self, forKey: .swapRateWarnMBPerMin) ?? 150
        swapRateDangerMBPerMin = try c.decodeIfPresent(Double.self, forKey: .swapRateDangerMBPerMin) ?? 400
        swapRateCriticalMBPerMin = try c.decodeIfPresent(Double.self, forKey: .swapRateCriticalMBPerMin) ?? 800
        recoveryWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .recoveryWindowSeconds) ?? 60
        recoveryObserveSeconds = try c.decodeIfPresent(Double.self, forKey: .recoveryObserveSeconds) ?? 45
    }
}

/// What the menu bar shows next to the shield icon.
enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case iconOnly
    case status
    case swap
    case pressure

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .status: return "状态文字"
        case .swap: return "Swap 用量"
        case .pressure: return "内存压力"
        }
    }
}

// MARK: - Managed / protected apps

struct ManagedAppConfig: Codable, Equatable, Identifiable {
    let key: String
    var displayName: String
    var allowAutoPause = false
    var allowEmergencyTerminate = false

    var id: String { key }

    // Seed list: units the aggregator recognizes, after process-tree rollup
    // the natural units are parent apps (ZCode → node/MCP/shell, IntelliJ →
    // java/Gradle, Xcode → xcodebuild/swiftc/sourcekitd).
    // Nothing is opted in by default — the user must flip the switches.
    static let defaults: [ManagedAppConfig] = [
        .init(key: "app:ZCode", displayName: "ZCode"),
        .init(key: "app:IntelliJ IDEA", displayName: "IntelliJ IDEA"),
        .init(key: "app:Cursor", displayName: "Cursor"),
        .init(key: "app:Code", displayName: "Visual Studio Code"),
        .init(key: "app:Xcode", displayName: "Xcode"),
        .init(key: "xcode", displayName: "Xcode 工具链"),
        .init(key: "sim", displayName: "模拟器"),
        .init(key: "app:Terminal", displayName: "终端"),
        .init(key: "codex", displayName: "Codex"),
        .init(key: "node", displayName: "node"),
        .init(key: "bun", displayName: "bun"),
    ]
}

struct AppSettings: Codable, Equatable {
    var notificationsEnabled = true
    var autoProtectionEnabled = false
    var autoResumeOnNormal = true
    var emergencyKillEnabled = false
    var emergencyKillDelaySeconds = 30
    var emergencyKillGraceSeconds = 15
    var menuBarDisplayMode: MenuBarDisplayMode = .status
    var protectedApps: [String] = []
    var managedApps: [ManagedAppConfig] = ManagedAppConfig.defaults
    var thresholds = ThresholdConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        autoProtectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoProtectionEnabled) ?? false
        autoResumeOnNormal = try c.decodeIfPresent(Bool.self, forKey: .autoResumeOnNormal) ?? true
        emergencyKillEnabled = try c.decodeIfPresent(Bool.self, forKey: .emergencyKillEnabled) ?? false
        emergencyKillDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .emergencyKillDelaySeconds) ?? 30
        emergencyKillGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .emergencyKillGraceSeconds) ?? 15
        menuBarDisplayMode = try c.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .status
        protectedApps = try c.decodeIfPresent([String].self, forKey: .protectedApps) ?? []
        managedApps = try c.decodeIfPresent([ManagedAppConfig].self, forKey: .managedApps) ?? ManagedAppConfig.defaults
        thresholds = try c.decodeIfPresent(ThresholdConfig.self, forKey: .thresholds) ?? ThresholdConfig()
    }

    static func == (lhs: AppSettings, rhs: AppSettings) -> Bool {
        lhs.notificationsEnabled == rhs.notificationsEnabled
            && lhs.autoProtectionEnabled == rhs.autoProtectionEnabled
            && lhs.autoResumeOnNormal == rhs.autoResumeOnNormal
            && lhs.emergencyKillEnabled == rhs.emergencyKillEnabled
            && lhs.emergencyKillDelaySeconds == rhs.emergencyKillDelaySeconds
            && lhs.emergencyKillGraceSeconds == rhs.emergencyKillGraceSeconds
            && lhs.menuBarDisplayMode == rhs.menuBarDisplayMode
            && lhs.protectedApps == rhs.protectedApps
            && lhs.managedApps == rhs.managedApps
            && lhs.thresholds == rhs.thresholds
    }
}
