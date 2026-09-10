import SwiftUI

// MARK: - Liquid Glass with pre-26 fallback

extension View {
    /// Card background: native glass effect on macOS 26+, ultra-thin
    /// material elsewhere. Keep surfaces restrained — no gradients.
    @ViewBuilder
    func cardBackground(_ cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            self
        }
    }
}

/// Groups cards so macOS 26+ merges their glass shapes.
struct CardsContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content }
        } else {
            content
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
