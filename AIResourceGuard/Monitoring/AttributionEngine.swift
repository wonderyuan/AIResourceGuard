import Foundation

/// How the current pressure episode is best explained.
enum PressureSource: Equatable {
    /// One process group is clearly running away.
    case singleRunaway(name: String)
    /// Many apps are mildly above normal at once — no single culprit.
    case widespread
    /// Page-out / decompression churn dominates; app-level growth is calm.
    case swapThrashing
    /// Left-behind orphan workloads hold most of the memory.
    case legacyAccumulation
    /// Build toolchain burst (xcodebuild / swiftc / java / gradle…).
    case buildBurst
    /// Attribution coverage too low to say anything honest.
    case incompleteAttribution
    /// Nothing abnormal (normal state).
    case none

    var label: String {
        switch self {
        case .singleRunaway: return "一个应用增长失控"
        case .widespread: return "多个应用同时在涨"
        case .swapThrashing: return "内存交换过于频繁"
        case .legacyAccumulation: return "遗留任务占用内存"
        case .buildBurst: return "构建任务高峰"
        case .incompleteAttribution: return "部分内存去向不明"
        case .none: return ""
        }
    }

    var symbol: String {
        switch self {
        case .singleRunaway: return "exclamationmark.arrow.circlepath"
        case .widespread: return "square.grid.3x3"
        case .swapThrashing: return "arrow.triangle.2.circlepath"
        case .legacyAccumulation: return "tray.full"
        case .buildBurst: return "hammer"
        case .incompleteAttribution: return "questionmark.circle"
        case .none: return ""
        }
    }
}

/// What the popover should render for "值得关注的应用".
struct NotableSelection {
    /// Ordered, deduplicated, capped list. At Danger/Critical this is
    /// guaranteed non-empty whenever the scan returned any group at all.
    var apps: [ProcessGroupInfo] = []
    /// A specific runaway / deviating / stale group was identified.
    var hasClearSource = false
    /// True when no specific source was found and the list is just the
    /// biggest current consumers — the UI must say so.
    var fallbackOnly = false
    /// Attribution coverage is too low to trust "everything looks fine".
    var attributionIncomplete = false
    /// Fraction of system-used memory the visible groups account for (0–1).
    var attributionCoverage: Double = 1
    var source: PressureSource = .none
}

/// Pure attribution logic: which apps deserve attention at this risk level,
/// what kind of pressure this is, and how much of the story we can actually
/// see. Physical footprint is the primary metric throughout.
enum AttributionEngine {

    static func analyze(level: RiskLevel,
                        sample: SystemSample?,
                        groups: [ProcessGroupInfo],
                        baseline: BaselineTracker,
                        scanStats: ScanStats?) -> NotableSelection {
        var result = NotableSelection()

        // --- Classify the participating groups --------------------------------
        let growers = groups
            .filter(\.isRiskSource)
            .sorted { $0.footprintTrendBytesPerMin > $1.footprintTrendBytesPerMin }
        let stale = groups.filter(\.isStaleWorkload)
            .sorted { $0.totalFootprint > $1.totalFootprint }
        var deviators: [(group: ProcessGroupInfo, excessMB: Double)] = []
        for group in groups {
            let current = Double(group.totalFootprint) / 1_048_576
            if let excess = baseline.groupFootprintExcessMB(groupKey: group.key, currentMB: current) {
                deviators.append((group, excess))
            }
        }
        deviators.sort { $0.excessMB > $1.excessMB }

        let paused = groups.filter(\.anyStopped)
        result.hasClearSource = !paused.isEmpty || !growers.isEmpty || !deviators.isEmpty || !stale.isEmpty

        // --- Attribution confidence --------------------------------------------
        let attributableFootprint = groups.reduce(0) { $0 + $1.totalFootprint }
        let systemUsed = sample.map { Double($0.usedBytes) } ?? 0
        result.attributionCoverage = systemUsed > 0
            ? min(1, Double(attributableFootprint) / systemUsed)
            : 1
        let failureRatio = scanStats?.failureRatio ?? 0
        result.attributionIncomplete =
            (failureRatio > 0.3 && level >= .warning)
            || (level >= .danger && result.attributionCoverage < 0.45)

        // --- Source classification ----------------------------------------------
        let staleFootprint = stale.reduce(0) { $0 + $1.totalFootprint }
        let staleDominates = staleFootprint > 1_000 * 1_048_576
            && Double(staleFootprint) > 0.3 * max(Double(attributableFootprint), 1)
        let buildish = { (group: ProcessGroupInfo) in
            group.key == "xcode"
                || group.key.hasPrefix("exe:swift")
                || group.key.hasPrefix("exe:clang")
                || group.key.hasPrefix("exe:java")
                || group.key.hasPrefix("exe:gradle")
                || group.key.hasPrefix("exe:xcodebuild")
        }

        if level == .normal {
            result.source = .none
        } else if result.attributionIncomplete
                    && growers.isEmpty && deviators.isEmpty && stale.isEmpty {
            result.source = .incompleteAttribution
        } else if staleDominates {
            result.source = .legacyAccumulation
        } else if growers.contains(where: buildish) {
            result.source = .buildBurst
        } else if let dominant = dominantGrower(growers, deviators: deviators) {
            result.source = .singleRunaway(name: dominant.displayName)
        } else if growers.count >= 3 || deviators.count >= 3 {
            result.source = .widespread
        } else if let sample, thrashing(sample) {
            result.source = .swapThrashing
        } else if !growers.isEmpty {
            result.source = .singleRunaway(name: growers[0].displayName)
        } else if !deviators.isEmpty {
            result.source = .singleRunaway(name: deviators[0].group.displayName)
        } else {
            result.source = .widespread
        }

        // --- Notable list, by risk level ---------------------------------------
        var ordered: [ProcessGroupInfo] = []
        func include(_ group: ProcessGroupInfo) {
            guard !ordered.contains(where: { $0.key == group.key }) else { return }
            ordered.append(group)
        }
        // Paused tasks ALWAYS appear first — the user needs the resume
        // button visible regardless of what else is happening.
        paused.forEach(include)
        growers.forEach(include)
        stale.forEach(include)
        deviators.forEach { include($0.group) }

        switch level {
        case .normal:
            // Only genuine concerns; never pad with big-but-stable apps.
            break
        case .warning:
            // Fill up to 3 with the largest visible consumers.
            fillFromLargest(&ordered, groups: groups, limit: 3)
        case .danger, .critical:
            // The list must never read as empty: fill to 5.
            fillFromLargest(&ordered, groups: groups, limit: 5)
        }

        result.fallbackOnly = level >= .danger && growers.isEmpty && deviators.isEmpty
        result.apps = Array(ordered.prefix(5))
        return result
    }

    // MARK: - Helpers

    /// A single group whose growth clearly outweighs everyone else's.
    private static func dominantGrower(
        _ growers: [ProcessGroupInfo],
        deviators: [(group: ProcessGroupInfo, excessMB: Double)]
    ) -> ProcessGroupInfo? {
        guard let top = growers.first else {
            return deviators.first?.group
        }
        let topRate = top.footprintTrendBytesPerMin
        let secondRate = growers.count > 1 ? growers[1].footprintTrendBytesPerMin : 0
        if topRate > 300 * 1_048_576 && topRate > 2 * max(secondRate, 1) {
            return top
        }
        return growers.count == 1 ? top : nil
    }

    private static func thrashing(_ sample: SystemSample) -> Bool {
        sample.pageoutRate >= 200 || sample.decompressionRate >= 50_000
    }

    /// Appends the largest user-visible groups (by footprint) until `limit`.
    private static func fillFromLargest(_ ordered: inout [ProcessGroupInfo],
                                        groups: [ProcessGroupInfo],
                                        limit: Int) {
        guard ordered.count < limit else { return }
        let candidates = groups
            .filter(\.isUserOwned)
            .sorted { $0.totalFootprint > $1.totalFootprint }
        for group in candidates where ordered.count < limit {
            if !ordered.contains(where: { $0.key == group.key }) {
                ordered.append(group)
            }
        }
        // Last resort at Danger/Critical: anything, even root-owned groups.
        if ordered.isEmpty, limit >= 5 {
            for group in groups.sorted(by: { $0.totalFootprint > $1.totalFootprint })
            where ordered.count < 3 {
                ordered.append(group)
            }
        }
    }
}
