# AI Resource Guard — Architecture (v2)

Native macOS menu-bar utility (no main window, MenuBarExtra popover is the
primary surface, all UI in Simplified Chinese). It watches memory pressure /
swap / process growth during AI-development workloads (ZCode, Cursor,
IntelliJ, Xcode, Simulator, node/MCP, xcodebuild) and helps pause or
terminate runaway task groups **before** the machine locks up.

v2 information architecture:
- Menu bar: shield glyph + short Chinese status word whenever not 正常.
- Popover: 一句话原因 (RiskEngine headline, e.g. "Swap 正在快速增长") →
  four core metrics → 值得关注的应用 (risk sources first: growing > 50 MB/min,
  then stable heavies > 300 MB; never top-by-RSS) → 自动保护 / 事件报告 / 设置.
- Process-tree rollup: name-based groups are adopted by their ancestor app
  (ZCode → node/MCP/shell, IntelliJ → java/Gradle, Xcode → xcodebuild…);
  detached daemons keep standalone groups.
- Every protection action feeds a one-line feedback banner in the popover
  ("已暂停 ZCode 任务", "系统压力已恢复").
- Incident report (timeline chart, heaviest processes) is a secondary
  black-box window (⌘I / popover / notification click), not the main UI.

## Design principles

1. **Public Apple APIs only.** Mach `host_statistics64`, `sysctl`, libproc
   (`proc_listallpids`, `proc_pid_rusage`, `proc_pidpath`, `proc_pidinfo`),
   `DispatchSource.makeMemoryPressureSource`, `SMAppService`,
   `UNUserNotificationCenter`. No private/undocumented API, no shell polling.
   (The only "re-declared in Swift" values are public-header C macros Swift
   cannot import: `RUSAGE_INFO_4 = 4`, `PROC_PIDTBSDINFO = 1`, `SSTOP = 4`,
   `CTL_KERN = 1`, `KERN_PROCARGS2 = 38`.)
2. **Event-driven pressure, adaptive cadence.** Memory pressure is a kernel
   dispatch source (instant transitions). Metrics poll at 5s (Normal) / 2s
   (Warning) / 1s (Danger+); process scans at 20s / 10s / 5s. UI-bound
   publishes are throttled to ~15s while the popover is closed.
3. **Never kill by "who is biggest".** A Protected Process Policy gates every
   signal-based action, manual or automatic. Risk decisions are multi-signal
   (pressure, swap level, swap rate, compression/decompression, page-outs,
   per-process-tree growth) with sustain windows, hysteresis and cooldown.
4. **The tool must be lighter than the problem it watches.** Single process,
   no XPC helpers, SQLite history capped at 24h / 1000 rows, all scanning on
   utility-QoS background queues.

## Module map

```
App
├── AIResourceGuardApp        @main, MenuBarExtra + Settings scenes, LSUIElement
├── Diagnostics               `--diagnostics` headless run-and-print mode
├── Monitoring
│   ├── MonitorCenter         @MainActor orchestrator, publishes to UI,
│   │                         adapts cadence, feeds RiskEngine & Protection
│   ├── MemoryPressureMonitor DispatchSource memory-pressure events
│   ├── SystemMetricsMonitor  host_statistics64 + vm.swapusage + hw.memsize
│   │                         + host_processor_info (CPU), rates & swap-rate window
│   ├── ProcessMonitor        proc_listallpids/rusage/pidpath/pidinfo scan,
│   │                         per-pid CPU deltas, per-group RSS trend rings
│   └── ProcessTreeAggregator pure grouping rules (app bundles, toolchain,
│                             node/bun→MCP via KERN_PROCARGS2 argv)
├── Monitoring
│   ├── BaselineTracker       machine-relative EWMA baselines (swap/page-out/
│   │                         decompression/group RSS), bootstrapped from history
├── Protection
│   ├── RiskEngine            pure scoring + hysteresis state machine (unit-tested);
│   │                         fixed thresholds × baseline-deviation signals
│   ├── ProtectedProcessPolicy pure allow/deny per action (unit-tested)
│   ├── RescueScorer          expected-release × abnormality × impact ranking,
│   │                         frontmost app strongly protected (unit-tested)
│   ├── RecoveryPlanner       staged resume state machine (unit-tested)
│   ├── IncidentSummarizer    rule-based post-mortem narrative (unit-tested)
│   └── ProtectionController  SIGSTOP/SIGCONT/SIGTERM (+SIGKILL last resort),
│                             rescue-scored targets, staged recovery, exit safety
├── Models                    SystemSample / ProcessRecord / ProcessGroupInfo /
│                             RiskInput / RiskAssessment / ThresholdConfig / AppSettings
├── Persistence
│   ├── HistoryStore          SQLite (C API) events: risk/pressure/snapshot/action
│   │                         + snapshot queries (timeline / lastSnapshotBefore)
│   └── SettingsStore         UserDefaults-backed Codable settings
├── Services
│   ├── Notifier              UNUserNotificationCenter wrapper + click delegate
│   ├── LaunchAtLogin         SMAppService.mainApp
│   └── IncidentWindowController  standalone NSWindow for the post-mortem report
└── UI
    ├── MenuBarLabel          status-colored shield glyph
    ├── DashboardView         400pt popover: Essentials / Risk / Top Consumers
    ├── ProcessGroupRow       expandable group detail + Pause/Resume/Terminate
    ├── HistoryView           6h timeline chart + event list (Settings ▸ History)
    ├── IncidentReportView    post-mortem window: stats / RiskTimeline / offenders
    └── SettingsView          General / Managed / Protected / Thresholds / History
```

## Data flow

```
kernel ──DispatchSource──▶ MemoryPressureMonitor ──event──┐
host_statistics64/sysctl ─▶ SystemMetricsMonitor ─sample──┤
libproc scan ────────────▶ ProcessMonitor ──groups────────┤
                                                          ▼
                                                    MonitorCenter
                     (merges, computes swap-rate & growth, throttled publish)
                        │                    │                 │
                  RiskEngine          HistoryStore       ProtectionController
                  (score, sustain,    (SQLite 24h/1000)  (policy gate → signals)
                   hysteresis,                                    │
                   cooldown)                              paused-by-us registry
                        │                                      │
                        ▼                                      ▼
                 MenuBar icon / notifications / popover    SIGSTOP/CONT/TERM/KILL
```

## Risk engine rules (v1 defaults)

Signals (each with a 0…1 severity; reasons kept for UI/history):

| Signal | Source | Warn / Danger / Critical |
|---|---|---|
| Kernel pressure | DispatchSource | warning=0.55, critical=1.0 |
| Swap used (weak signal, capped at 0.6) | `vm.swapusage` | 2 GB / 5 GB / 9 GB |
| Swap growth rate | 60s sliding window | 150 / 400 / 800 MB/min |
| Physical memory used | (wire+active+compressed)/hw.memsize | 90% / 93% / 97% |
| Page-outs | vm_statistics64 deltas | 50 / 200 / 800 pps |
| Decompression (supporting signal) | vm_statistics64 deltas | 20k / 50k / 100k pps |
| Per-group RSS growth | 5-min trend ring | 100 / 250 / 600 MB/min |

Score = max(signal severities) + 0.05 per additional signal ≥ 0.4 (capped 1.0).
Levels: Warning ≥ 0.35, Danger ≥ 0.60, Critical ≥ 0.85.

State machine: escalation requires the *same* higher level sustained for
12s (Warning) / 10s (Danger) / 6s (Critical); de-escalation requires score
below (threshold − 0.12) sustained 30s. Notification cooldown 120s per level;
auto-pause cooldown 90s; emergency-kill needs sustained Critical for a
configurable delay (default 30s) and SIGTERM→15s grace→SIGKILL only as the
final fallback, only for apps the user explicitly enabled.

## Action policy

- Protected, always: `kernel_task`, `launchd`, `WindowServer`, `loginwindow`,
  `Finder`, `Dock`, `SystemUIServer` + a fixed list of critical daemons; any
  root-owned process; executables under `/System`, `/usr/libexec`,
  `/usr/sbin`, `/sbin`, `/usr/lib`, `/Library/Apple` (developer tools such as
  `xcodebuild`/`swiftc` exempted by name); the app itself; user's Protected
  Apps list.
- Automatic actions additionally require the group to be in Managed Apps
  with the corresponding opt-in flag (default: everything off).
- Manual Terminate = SIGTERM; manual Force (with confirmation) = SIGKILL.
  Automatic force-kill is impossible by construction.

## Persistence

`~/Library/Application Support/AI Resource Guard/history.sqlite` (WAL).
Kinds: `launch`, `pressureChange`, `riskChange`, `snapshot` (top consumers +
fastest-growing every 30–120s by level), `action`. Pruned to 24h / 1000 rows.

## Known v1 boundaries

- No App Sandbox, no Hardened Runtime requirement (documented; needed to
  read rusage of and signal other user processes).
- Notification authorization requested on first launch (standard TCC prompt).
- Launch at Login uses `SMAppService`; ad-hoc dev builds registered from a
  stable path (e.g. /Applications) work best.
- Root-owned dev processes cannot be paused/killed without root; they are
  reported as protected instead.
- The baseline needs ≥ 60 normal-state samples before its deviation signals
  activate (bootstrapped from history, so usually ready within minutes of
  first launch on a machine with prior history).
