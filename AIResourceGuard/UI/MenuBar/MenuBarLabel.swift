import SwiftUI

/// The menu-bar status itself: shield glyph by level, plus a short Chinese
/// status word whenever the system is not normal — the user should never
/// need to open anything to know something is wrong.
struct MenuBarLabel: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        let level = store.assessment.level
        HStack(spacing: 3) {
            Image(systemName: level.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(level.color))
            if level != .normal {
                Text(level.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(level.color)
            }
        }
    }
}
