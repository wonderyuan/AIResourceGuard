import Foundation

enum ProcessAction {
    case pause        // SIGSTOP
    case resume       // SIGCONT
    case terminate    // SIGTERM
    case forceTerminate // SIGKILL — manual only, with confirmation
}

struct PolicyDecision: Equatable {
    let allowed: Bool
    let reason: String?

    static let allowed = PolicyDecision(allowed: true, reason: nil)

    static func denied(_ reason: String) -> PolicyDecision {
        PolicyDecision(allowed: false, reason: reason)
    }
}

/// Gates every signal-based action (manual and automatic). A protected
/// process can never be paused, resumed or terminated by this app.
///
/// Protected, in order:
/// 1. the app itself (pid and bundle path)
/// 2. well-known system process names
/// 3. any root-owned process (system daemons; we could not signal them anyway)
/// 4. executables under system paths, minus developer tools exempted by name
/// 5. groups in the user's Protected Apps list
///
/// Automatic actions additionally require the group to be a Managed App with
/// the matching opt-in flag; automatic SIGKILL is impossible by construction.
struct ProtectedProcessPolicy {
    var selfPid: Int32

    static let systemProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock",
        "SystemUIServer", "logd", "syslogd", "sysmond", "watchdogd", "coreaudiod",
        "powerd", "hidd", "bluetoothd", "securityd", "trustd", "configd",
        "mDNSResponder", "mds", "mds_stores", "mdworker", "mdworker_shared",
        "UserEventAgent", "cfprefsd", "distnoted", "backgroundtaskmanagementd",
    ]

    static let protectedPathPrefixes: [String] = [
        "/System", "/usr/libexec", "/usr/sbin", "/sbin", "/usr/lib",
        "/Library/Apple", "/private/var/db",
    ]

    /// Developer tools that legitimately live under system paths (e.g.
    /// `/usr/bin/xcodebuild` shims) and must remain manageable.
    static let devToolExceptions: Set<String> = [
        "xcodebuild", "swiftc", "swift", "clang", "clang++", "ld", "sourcekitd",
        "git", "node", "bun", "codex",
    ]

    func validate(pid: Int32,
                  name: String,
                  path: String,
                  euid: Int32?,
                  groupKey: String,
                  action: ProcessAction,
                  isAutomatic: Bool,
                  settings: AppSettings,
                  selfPath: String) -> PolicyDecision {
        if pid == selfPid {
            return .denied("AI Resource Guard itself")
        }
        if Self.systemProcessNames.contains(name) {
            return .denied("Protected system process: \(name)")
        }
        if let euid, euid == 0 {
            return .denied("Root-owned system process")
        }
        if !path.isEmpty {
            let executable = (path as NSString).lastPathComponent
            if !Self.devToolExceptions.contains(executable),
               Self.protectedPathPrefixes.contains(where: { path.hasPrefix($0) }) {
                return .denied("Protected system path")
            }
            if !selfPath.isEmpty, path.hasPrefix(selfPath) {
                return .denied("AI Resource Guard itself")
            }
        }
        if settings.protectedApps.contains(groupKey) {
            return .denied("In your Protected Apps list")
        }

        if isAutomatic {
            guard action != .forceTerminate else {
                return .denied("Automatic force-kill is never permitted")
            }
            guard let managed = settings.managedApps.first(where: { $0.key == groupKey }) else {
                return .denied("Not a Managed App")
            }
            switch action {
            case .pause, .resume:
                guard managed.allowAutoPause else {
                    return .denied("Auto-pause not enabled for \(managed.displayName)")
                }
            case .terminate:
                guard settings.emergencyKillEnabled, managed.allowEmergencyTerminate else {
                    return .denied("Emergency terminate not enabled for \(managed.displayName)")
                }
            case .forceTerminate:
                return .denied("Automatic force-kill is never permitted")
            }
        }
        return .allowed
    }
}
