import SwiftUI

/// The product's own design language: one place for spacing, typography,
/// corner radii and motion — so surfaces stop being assembled from ad-hoc
/// numbers and scattered glassEffect calls.
enum Design {
    // Spacing scale.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 14
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // Typography hierarchy (system fonts, semantic roles).
    enum Typo {
        /// The one big number on a surface (系统余量).
        static let heroValue = Font.system(size: 34, weight: .semibold, design: .rounded)
        /// Panel titles.
        static let title = Font.title3.weight(.semibold)
        /// Primary sentence.
        static let headline = Font.headline
        static let headlineEmphasis = Font.system(.body, design: .rounded).weight(.semibold)
        /// Body copy in popovers.
        static let body = Font.callout
        /// Secondary information.
        static let footnote = Font.caption
        /// Section labels / tags.
        static let micro = Font.caption2
        /// Monospaced numerals in body size.
        static let number = Font.callout.monospacedDigit()
    }

    // Corner radii.
    enum Radius {
        static let panel: CGFloat = 12
        static let tag: CGFloat = 6
    }

    // Motion rhythm: fast for state flips, standard for layout changes.
    enum Motion {
        static let fast = Animation.easeOut(duration: 0.15)
        static let standard = Animation.easeInOut(duration: 0.25)
    }
}

extension View {
    /// Glass surface for *key interactive* areas only (expanded app panel,
    /// report sections). The popover itself is already a native glass window.
    @ViewBuilder
    func glassSurface(_ cornerRadius: CGFloat = Design.Radius.panel) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.quaternary.opacity(0.4), in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// Glass button for primary inline actions (暂停任务 / 恢复任务).
    @ViewBuilder
    func glassActionButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }

    /// Small status tag (增长异常 / 遗留任务 / MCP).
    func tagStyle(_ color: Color) -> some View {
        font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Level colors

extension RiskLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .danger: return .orange
        case .critical: return .red
        }
    }

    var menuBarIcon: String {
        switch self {
        case .normal: return "shield"
        case .warning: return "shield.lefthalf.filled"
        case .danger: return "exclamationmark.shield"
        case .critical: return "exclamationmark.shield.fill"
        }
    }
}

extension PressureLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

// MARK: - App icons

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 20, height: 20)
        cache[path] = icon
        return icon
    }
}
