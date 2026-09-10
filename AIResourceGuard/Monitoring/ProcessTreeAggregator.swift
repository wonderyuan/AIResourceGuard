import Foundation

/// Pure rules that collapse individual processes into the groups shown in the
/// UI and referenced by Managed/Protected lists:
///   - everything inside `X.app` → one group for X (Cursor, Code, Xcode, …)
///   - Xcode build toolchain binaries (`xcodebuild`, `swiftc`, `sourcekitd`,
///     `clang`, …) roll into "Xcode & Toolchain"
///   - CoreSimulator runtime processes → "Simulator"
///   - `node`/`bun`/`deno` whose argv mentions an MCP server → "MCP Server"
///   - everything else groups by executable name
enum ProcessTreeAggregator {
    static let xcodeToolchainNames: Set<String> = [
        "xcodebuild", "xctest", "swiftc", "swift", "swift-frontend", "swift-driver",
        "swift-package-executable", "clang", "clang++", "ld", "ld64", "sourcekitd",
        "sourcekit-lsp", "ibtool", "actool", "momc", "mapc", "XCBBuildService",
        "swift-format", "swift-demangle", "dsymutil",
    ]

    static let knownAppGroups: [String: String] = [
        "Cursor": "app:Cursor",
        "Code": "app:Code",
        "Xcode": "xcode",
        "Codex": "codex",
        "Simulator": "sim",
        "iOS Simulator": "sim",
    ]

    static let knownAppDisplayNames: [String: String] = [
        "app:Code": "Visual Studio Code",
        "xcode": "Xcode & Toolchain",
    ]

    /// Returns `.app` bundle name when the path points inside a bundle's
    /// `Contents/` tree (heuristic but reliable for helper processes).
    static func appBundleName(path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        let prefix = String(path[path.startIndex..<range.lowerBound])
        let name = (prefix as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Bundle directory path (for fetching the app icon), or nil.
    static func appBundlePath(path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    static func classify(name: String, path: String, isMCP: Bool)
        -> (key: String, display: String, isApp: Bool) {
        if let app = appBundleName(path: path) {
            let key = knownAppGroups[app] ?? "app:\(app)"
            let display = key == "xcode" ? "Xcode & Toolchain"
                : (knownAppDisplayNames[key] ?? app)
            return (key, display, true)
        }
        if path.contains("CoreSimulator") || path.contains("SimRuntime") {
            return ("sim", "Simulator", false)
        }
        switch name {
        case "node", "npx":
            return isMCP ? ("mcp-node", "MCP Server (node)", false)
                         : ("node", "node", false)
        case "bun":
            return isMCP ? ("mcp-bun", "MCP Server (bun)", false)
                         : ("bun", "bun", false)
        case "deno":
            return isMCP ? ("mcp-deno", "MCP Server (deno)", false)
                         : ("deno", "deno", false)
        case "codex", "codex-exec", "codex-cli":
            return ("codex", "Codex", false)
        default:
            break
        }
        if xcodeToolchainNames.contains(name) {
            return ("xcode", "Xcode & Toolchain", false)
        }
        return ("exe:\(name)", name, false)
    }
}
