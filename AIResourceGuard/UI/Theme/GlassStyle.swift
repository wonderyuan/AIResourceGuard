import SwiftUI

// MARK: - Liquid Glass, used sparingly

extension View {
    /// Glass surface for *key interactive* areas only (expanded app detail,
    /// incident cards). The popover itself is already a native glass window —
    /// inner content stays plain with native typography and spacing.
    @ViewBuilder
    func glassSurface(_ cornerRadius: CGFloat = 12) -> some View {
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
}

// MARK: - Level colors (restrained, semantic)

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
