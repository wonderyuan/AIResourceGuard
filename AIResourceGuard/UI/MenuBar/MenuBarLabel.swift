import SwiftUI

/// The menu-bar status itself. Shield glyph always reflects the level; the
/// text beside it follows the user's display-mode choice and stays restrained
/// while everything is normal — the abnormal state is what deserves pixels.
struct MenuBarLabel: View {
    @EnvironmentObject var store: MonitorCenter
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        let level = store.assessment.level
        HStack(spacing: 3) {
            Image(systemName: level.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
            trailingText(level: level)
        }
        .foregroundStyle(level == .normal ? Color.primary : level.color)
    }

    @ViewBuilder
    private func trailingText(level: RiskLevel) -> some View {
        switch settings.settings.menuBarDisplayMode {
        case .iconOnly:
            EmptyView()
        case .status:
            // 克制：正常时不占菜单栏空间，异常时才亮出文字。
            if level != .normal {
                Text(level.label)
                    .font(.system(size: 11, weight: .medium))
            }
        case .swap:
            // 只在 Swap 真正被使用时显示，避免常态噪音。
            if let swapMB = store.system.map({ Double($0.swapUsedBytes) / 1_048_576 }), swapMB > 1024 {
                Text(swapMB >= 1024
                     ? String(format: "%.1fG", swapMB / 1024)
                     : String(format: "%.0fM", swapMB))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(swapMB > 8192 ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.secondary))
            }
        case .pressure:
            // 压力正常是常态，只在警告/严重时提醒。
            if store.pressureLevel != .normal {
                Text(store.pressureLevel.label)
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }
}
