import Foundation

/// Pure rules that collapse individual processes into "task groups".
///
/// Classification order:
/// 1. A process whose own executable lives inside `X.app` belongs to X
///    (Cursor + Cursor Helper, Xcode + xcodebuild/swiftc/sourcekitd…).
/// 2. Otherwise, ProcessMonitor walks the ppid chain: the first ancestor
///    inside an app bundle claims the process — ZCode → node/MCP/shell,
///    IntelliJ → java/Gradle, 终端 → CLI-launched tools. Detached daemons
///    (reparented to launchd) fall through to name-based groups.
/// 3. CoreSimulator runtime processes → 模拟器.
/// 4. Fallback: group by executable name.
enum ProcessTreeAggregator {
    /// Bundles that map to a dedicated (non `app:`) group key.
    static let knownAppGroups: [String: String] = [
        "Cursor": "app:Cursor",
        "Code": "app:Code",
        "Xcode": "app:Xcode",
        "ZCode": "app:ZCode",
        "Codex": "codex",
        "Simulator": "sim",
        "iOS Simulator": "sim",
    ]

    /// Chinese / friendly display names for group keys.
    static let displayNames: [String: String] = [
        "app:Code": "Visual Studio Code",
        "app:Terminal": "终端",
        "app:System Settings": "系统设置",
        "sim": "模拟器",
        "xcode": "Xcode 工具链",
    ]

    /// Toolchain binaries that still make sense as a standalone fallback
    /// group when no ancestor app can be found (CLI / detached).
    static let xcodeToolchainNames: Set<String> = [
        "xcodebuild", "xctest", "swiftc", "swift", "swift-frontend", "swift-driver",
        "swift-package-executable", "clang", "clang++", "ld", "ld64", "sourcekitd",
        "sourcekit-lsp", "ibtool", "actool", "momc", "mapc", "XCBBuildService",
        "swift-format", "swift-demangle", "dsymutil",
    ]

    static func appBundleName(path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        let prefix = String(path[path.startIndex..<range.lowerBound])
        let name = (prefix as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func appBundlePath(path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    /// Stable group identity + display name for an app bundle.
    static func appGroup(forBundle bundleName: String) -> (key: String, display: String) {
        let key = knownAppGroups[bundleName] ?? "app:\(bundleName)"
        let display = displayNames[key] ?? bundleName
        return (key, display)
    }

    /// Standalone classification (before ancestor rollup).
    static func classify(name: String, path: String)
        -> (key: String, display: String, isApp: Bool) {
        if let bundle = appBundleName(path: path) {
            let group = appGroup(forBundle: bundle)
            return (group.key, group.display, true)
        }
        if path.contains("CoreSimulator") || path.contains("SimRuntime") {
            return ("sim", "模拟器", true)
        }
        switch name {
        case "codex", "codex-exec", "codex-cli":
            return ("codex", "Codex", true)
        default:
            break
        }
        if xcodeToolchainNames.contains(name) {
            return ("xcode", "Xcode 工具链", false)
        }
        return ("exe:\(name)", name, false)
    }
}
