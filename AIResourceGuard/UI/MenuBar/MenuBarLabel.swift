import SwiftUI

/// The menu-bar status icon. Shape encodes the level (works in monochrome);
/// a subtle tint is applied for Warning and above.
struct MenuBarLabel: View {
    @EnvironmentObject var store: MonitorCenter

    var body: some View {
        let level = store.assessment.level
        Image(systemName: level.menuBarIcon)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(level.color))
    }
}
