import XCTest
@testable import AIResourceGuard

final class ProtectedProcessPolicyTests: XCTestCase {
    private let policy = ProtectedProcessPolicy(selfPid: 999)
    private let selfPath = "/Applications/AI Resource Guard.app"

    private func validate(
        pid: Int32 = 100,
        name: String = "Cursor",
        path: String = "/Applications/Cursor.app/Contents/MacOS/Cursor",
        euid: Int32? = 501,
        group: String = "app:Cursor",
        action: ProcessAction = .pause,
        isAutomatic: Bool = false,
        settings: AppSettings = AppSettings()
    ) -> PolicyDecision {
        policy.validate(
            pid: pid, name: name, path: path, euid: euid, groupKey: group,
            action: action, isAutomatic: isAutomatic,
            settings: settings, selfPath: selfPath)
    }

    // MARK: - Always protected

    func testSelfPidIsProtected() {
        XCTAssertFalse(validate(pid: 999).allowed)
    }

    func testSelfBundlePathIsProtected() {
        let decision = validate(
            pid: 500, name: "AI Resource Guard",
            path: "/Applications/AI Resource Guard.app/Contents/MacOS/AI Resource Guard",
            group: "app:AI Resource Guard")
        XCTAssertFalse(decision.allowed)
    }

    func testSystemProcessNamesAreProtected() {
        for name in ["kernel_task", "launchd", "WindowServer", "loginwindow",
                     "Finder", "Dock", "SystemUIServer", "coreaudiod"] {
            XCTAssertFalse(
                validate(pid: 2, name: name, path: "/sbin/\(name)").allowed,
                "\(name) must be protected")
        }
    }

    func testSystemPathsAreProtected() {
        for path in ["/usr/libexec/coreaudiod", "/System/Library/Frameworks/foo.bar",
                     "/usr/sbin/mDNSResponder", "/sbin/launchd", "/usr/lib/libfoo.dylib"] {
            XCTAssertFalse(
                validate(pid: 3, name: "foo", path: path, group: "exe:foo").allowed,
                "\(path) must be protected")
        }
    }

    func testRootOwnedProcessesAreProtected() {
        XCTAssertFalse(validate(euid: 0).allowed)
    }

    func testUserProtectedGroupsAreProtected() {
        var settings = AppSettings()
        settings.protectedApps = ["app:Cursor"]
        XCTAssertFalse(validate(settings: settings).allowed)
    }

    func testSystemAppsUnderSystemApplicationsAreProtected() {
        // Safari lives under /System/Applications — must be protected.
        let decision = validate(
            pid: 400, name: "Safari",
            path: "/System/Applications/Safari.app/Contents/MacOS/Safari",
            group: "app:Safari")
        XCTAssertFalse(decision.allowed)
    }

    // MARK: - Allowed

    func testUserAppIsAllowedForManualActions() {
        XCTAssertTrue(validate().allowed)
    }

    func testNodeFromNvmIsAllowed() {
        XCTAssertTrue(validate(
            pid: 120, name: "node",
            path: "/Users/dev/.nvm/versions/node/v22.0.0/bin/node",
            group: "node").allowed)
    }

    func testXcodebuildUnderUsrBinIsAllowedViaDevToolException() {
        XCTAssertTrue(validate(
            pid: 130, name: "xcodebuild",
            path: "/usr/bin/xcodebuild",
            group: "xcode").allowed)
    }

    // MARK: - Automatic actions require opt-in

    func testAutoPauseRequiresManagedConfig() {
        XCTAssertFalse(validate(isAutomatic: true).allowed)
    }

    func testAutoPauseRequiresAllowAutoPauseFlag() {
        var settings = AppSettings()
        settings.managedApps = [ManagedAppConfig(key: "app:Cursor", displayName: "Cursor")]
        XCTAssertFalse(validate(isAutomatic: true, settings: settings).allowed)

        settings.managedApps[0].allowAutoPause = true
        XCTAssertTrue(validate(isAutomatic: true, settings: settings).allowed)
    }

    func testAutoTerminateRequiresEmergencyKillEnabledAndFlag() {
        var settings = AppSettings()
        settings.managedApps = [ManagedAppConfig(key: "app:Cursor", displayName: "Cursor")]
        settings.managedApps[0].allowEmergencyTerminate = true
        // Emergency kill globally off → denied.
        XCTAssertFalse(validate(action: .terminate, isAutomatic: true, settings: settings).allowed)

        settings.emergencyKillEnabled = true
        XCTAssertTrue(validate(action: .terminate, isAutomatic: true, settings: settings).allowed)
    }

    func testAutomaticForceKillIsImpossible() {
        var settings = AppSettings()
        settings.emergencyKillEnabled = true
        settings.managedApps = [ManagedAppConfig(key: "app:Cursor", displayName: "Cursor")]
        settings.managedApps[0].allowAutoPause = true
        settings.managedApps[0].allowEmergencyTerminate = true
        XCTAssertFalse(validate(action: .forceTerminate, isAutomatic: true, settings: settings).allowed)
    }

    func testProtectedGroupBlocksEvenManualActions() {
        var settings = AppSettings()
        settings.protectedApps = ["node"]
        XCTAssertFalse(validate(
            pid: 200, name: "node",
            path: "/opt/homebrew/bin/node",
            group: "node", settings: settings).allowed)
    }
}
