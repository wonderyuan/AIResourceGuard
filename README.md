# AI Resource Guard

原生 macOS 菜单栏常驻应用：在跑 Codex / Cursor / Xcode / Simulator / node / MCP Server
等 AI 开发任务时，提前发现内存恶化趋势（Memory Pressure / Swap 增速 / 压缩抖动 /
进程树 RSS 增长），在机器卡死之前发出警告，并允许安全地 Pause / Resume / Terminate
失控进程。

## 构建与运行

```bash
cd AIResourceGuard
xcodebuild -project AIResourceGuard.xcodeproj -scheme "AI Resource Guard" \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData build
open "build/DerivedData/Build/Products/Debug/AI Resource Guard.app"
```

或直接用 Xcode 打开 `AIResourceGuard.xcodeproj`，Cmd+R 运行。
建议把 `AI Resource Guard.app` 拷贝到 /Applications 长期使用（登录启动需要稳定路径）。

- 启动后常驻菜单栏，无 Dock 图标、无主窗口（LSUIElement）。
- 点击菜单栏盾牌图标打开 Popover（400pt 宽）。
- 无 App Sandbox、无 Hardened Runtime、ad-hoc 签名：读取其他进程的 rusage
  与发送信号需要这些能力，这是有意的选择。

## 状态与治理

Risk Engine 综合以下信号打分（0–1），分为 Normal / Warning / Danger / Critical：

- 内核 Memory Pressure（DispatchSource 事件，即时）
- Swap 使用量（默认 2 / 5 / 9 GB 三档，弱信号，最高只到 0.7——常态高 swap 的机器不会
  仅因绝对值就冲到 Critical）
- Swap 增长速度（60 秒滑窗，150 / 400 / 800 MB/min 三档）
- 物理内存占用（wire+active+compressed）
- Page-out 与解压缩速率（thrashing 迹象）
- 单进程组 RSS 持续增长（5 分钟窗口趋势）

升级需要同级别信号**持续** 12/10/6 秒；降级需要低于阈值 0.12 且持续 30 秒（hysteresis）；
同一级别通知有 120 秒冷却。所有阈值可在 Settings ▸ Thresholds 调整。

- **Warning**：菜单栏图标变化 + 原生通知（含 Top 3 进程）。
- **Danger**：再次通知，并标注内存增长最快的进程；Popover 内可对任意非保护进程组
  一键 Pause（SIGSTOP）/ Resume（SIGCONT）/ Terminate（SIGTERM）。
- **Critical + Auto Protection**：自动 Pause 用户在 Managed Apps 里明确勾选的应用；
  回到 Normal 后自动 Resume。
- **Critical + Emergency Terminate（默认关闭）**：持续 Critical 达到设定时长后，
  对明确勾选的应用 SIGTERM，宽限期后仍存活才用 SIGKILL 兜底（仅此一种自动 SIGKILL 场景）。

## 安全机制

- 保护名单（永不触碰）：kernel_task、launchd、WindowServer、loginwindow、Finder、
  Dock、SystemUIServer 等系统进程；所有 root 进程；/System、/usr/libexec、/usr/sbin、
  /sbin、/Library/Apple 路径下的进程（xcodebuild 等开发工具按名称豁免）；应用自身；
  以及用户在 Protected Apps 里添加的任意组。
- 自动动作必须同时满足：目标在 Managed Apps 列表 + 用户勾选了对应开关 + 当前是
  Critical + 保护检查通过。默认所有开关关闭，第一版不会自动处理任何应用。
- 自动 SIGKILL 仅存在于"Emergency Terminate + SIGTERM 宽限期超时"这一条链路。

## 历史记录与事故报告

SQLite（WAL）写入 `~/Library/Application Support/AI Resource Guard/history.sqlite`：
风险级别变化、压力变化、每 30–120 秒的系统快照（含 Top 5 进程与增长最快进程）、
所有手动/自动动作。保留 24 小时 / 1000 条。

**事故报告（v1.1）**：
- 菜单栏 Popover 底部 "Report" 按钮 / 应用菜单 ⌘I / **点击任意风险通知** 都可打开
  Incident Report 窗口；
- 时间线图（1h/6h/24h）：内存/swap 曲线 + 风险级别色带 + swap 峰值标记；
- "Heaviest processes"：窗口期内每个进程组的峰值 RSS 与出现时间——直接回答
  "是哪个进程在什么时候把系统拖垮了"；
- App 重启时如果检测到上次会话的最后快照处于 Danger/Critical，会立即记录
  "Previous session ended at …" 事件并发通知（机器卡死重启后第一次打开就能看到）。

Settings ▸ History 顶部同样展示最近 6 小时时间线，下方为完整事件列表。

## 性能设计

- Memory Pressure 用内核事件源，不轮询。
- 系统指标 5s（Normal）/ 2s（Warning）/ 1s（Danger+）自适应。
- 进程扫描 20s / 10s / 5s 自适应；单次扫描为纯 libproc 系统调用，无 shell。
- Popover 关闭时 UI 数据发布节流到 ~15s；空闲 CPU 目标 ≈ 0%。

## 公开 API 清单（无私有 API）

- `DispatchSource.makeMemoryPressureSource`
- `host_statistics64(HOST_VM_INFO64)`、`host_processor_info(HOST_CPU_LOAD_INFO)`
- `sysctlbyname("vm.swapusage" / "hw.memsize")`、`KERN_PROCARGS2`
- `proc_listallpids` / `proc_pid_rusage` / `proc_pidpath` / `proc_pidinfo` / `proc_name`
- `kill` (SIGSTOP/SIGCONT/SIGTERM/SIGKILL)、`SMAppService`、`UNUserNotificationCenter`
- SwiftUI `MenuBarExtra`（macOS 13+），Liquid Glass `glassEffect` /
  `GlassEffectContainer` / `.buttonStyle(.glass)`（macOS 26+，旧系统自动回退到
  `.ultraThinMaterial`）

## 已知边界

- 需要 TCC 通知权限（首次启动会请求）；未授权时通知静默丢弃，其余功能不受影响。
- root 进程（如 sudo 启动的构建）无法被暂停/终止，会被标记为受保护。
- Launch at Login 用 SMAppService；ad-hoc 签名 + 稳定路径（/Applications）下工作，
  从 DerivedData 运行时可能注册失败（Settings 里会显示错误）。
- `--diagnostics` 命令行参数：无 UI 跑 14 秒真实监控并打印（验证用）。

## 开发

- 架构说明见 [ARCHITECTURE.md](ARCHITECTURE.md)。
- 单元测试仅覆盖 RiskEngine（滞回/持续/冷却）与 ProtectedProcessPolicy（保护规则）：
  `xcodebuild test -project AIResourceGuard.xcodeproj -scheme "AI Resource Guard"`。
