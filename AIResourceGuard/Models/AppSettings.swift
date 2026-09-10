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
    var protectedApps: [String] = []
    var managedApps: [ManagedAppConfig] = ManagedAppConfig.defaults
    var thresholds = ThresholdConfig()

    static func == (lhs: AppSettings, rhs: AppSettings) -> Bool {
        lhs.notificationsEnabled == rhs.notificationsEnabled
            && lhs.autoProtectionEnabled == rhs.autoProtectionEnabled
            && lhs.autoResumeOnNormal == rhs.autoResumeOnNormal
            && lhs.emergencyKillEnabled == rhs.emergencyKillEnabled
            && lhs.emergencyKillDelaySeconds == rhs.emergencyKillDelaySeconds
            && lhs.emergencyKillGraceSeconds == rhs.emergencyKillGraceSeconds
            && lhs.protectedApps == rhs.protectedApps
            && lhs.managedApps == rhs.managedApps
            && lhs.thresholds == rhs.thresholds
    }
}
