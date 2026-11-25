# LynxBar 核心架构与设计规范

> **状态**：V2 核心架构、`LynxBar` 品牌重命名（M2）、Change F 技术债收尾（M3）及 Opt-in AI 订阅配额模块（M4）均已实施；当前架构基线与实现规格对齐 [`lynxbar-ai-quota-and-opensource-plan.md`](./lynxbar-ai-quota-and-opensource-plan.md)  
> **实施边界说明**：按需采样、双外观语义 `Theme`、GPU / 电池 / 热状态、`AccessoryPower`、Trash-safe `DiskCleanup`、`history-v3.plist` 有界历史、`LynxBar` 全局品牌与图标脚手架（`com.swnb.LynxBar`）、`os.Logger` 结构化诊断、`Public IP` 默认关闭、`LynxBar.entitlements`、外观偏好（`System / Dark / Light`）及 AI 订阅配额模块（`AIUsage`）均已在当前代码基线落地。  
> **适用范围**：LynxBar macOS 菜单栏系统监控面板（`App/`、`Kit/`、`Providers/`、`Modules/`）  
> **关联规划**：AI 订阅配额监控、Change F 收尾与开源标准化方案见 [`lynxbar-ai-quota-and-opensource-plan.md`](./lynxbar-ai-quota-and-opensource-plan.md)

---

## 目录与快速导航

1. [设计目标与边界（Design Goals & Non-Goals）](#1-设计目标与边界design-goals--non-goals)
2. [信息架构与面板布局（Information Architecture & Panel Frame）](#2-信息架构与面板布局information-architecture--panel-frame)
3. [按需采样与生命周期（Demand-Driven Sampling）](#3-按需采样与生命周期demand-driven-sampling)
4. [指标口径与系统数据源（Metric Definitions & System Sources）](#4-指标口径与系统数据源metric-definitions--system-sources)
5. [健康评估与行动规则（System Health & Action Rules）](#5-健康评估与行动规则system-health--action-rules)
6. [采样周期、有界历史与时间窗口（Cadence, Bounded History & Range Semantics）](#6-采样周期有界历史与时间窗口cadence-bounded-history--range-semantics)
7. [视觉系统、交互与辅助功能（Visual System, Interaction & Accessibility）](#7-视觉系统交互与辅助功能visual-system-interaction--accessibility)
8. [代码模块映射（Module Mapping）](#8-代码模块映射module-mapping)
9. [设计权衡与已知约束（Tradeoffs & Known Constraints）](#9-设计权衡与已知约束tradeoffs--known-constraints)

---

## 1. 设计目标与边界（Design Goals & Non-Goals）

### 设计目标

- **三秒判读原则**：用户打开 `420 × 600` points 菜单栏面板后，可在三秒内回答三个问题——系统是否正常、哪个资源值得关注、下一步去哪里查看或处理。
- **高信噪比 Overview**：`Overview` 只呈现核心资源决策摘要、一个主趋势、可解释 `Attention` 和真实 `Top processes`，不把所有底层采样字段平铺在首屏。
- **语义对齐的详情页**：每个资源详情提供与决策相匹配的时间范围、上下文和行动入口（例如 `Disk` 中的安全移至废纸篓清理工作流、`CPU`/`Memory` 中的进程处置上下文）。
- **诚实与真实边界**：所有范围切换、排序、复制、导航、展开和设置均有真实行为、状态反馈、辅助功能语义与中英文文案；历史数据遵守真实时间边界、有界存储和诚实的 warm-up，不插值、不伪造应用未运行期间的数据。

### 边界与非目标

- 不将“内存容量已用比例”伪装成 macOS memory pressure。
- 不伪造未建立可靠系统来源的指标（如磁盘 I/O 吞吐 / IOPS 曲线）；磁盘面板只展示真实容量与历史。
- 不静默终止进程、不静默自动删除文件（所有磁盘清理仅通过确认后移至废纸篓执行）、不修改系统网络或内存配置。
- 不引入 Web UI、常驻后台 daemon、远程数据库或第三方运行时依赖。

---

## 2. 信息架构与面板布局（Information Architecture & Panel Frame）

### 2.1 固定面板框架

下拉面板由 `PanelHost` 管理的无边框 `NSPanel`（圆角 `10pt`）承载，尺寸固定为 `420 × 600` points，由三层组成：

1. **顶部品牌与设备状态（`DashboardHeader`，高 `42pt`）**：展示应用名称、当前设备名、实时状态（`Live`）与 `Settings` 齿轮按钮。
2. **中间工作区（自适应剩余高度）**：承载当前选中的页面（`Overview`、各已启用资源详情、`AI` 或 `Settings`）；内容超出可视高度时仅此区域纵向滚动。
3. **底部固定导航（`BottomNavigation`，高 `62pt`）**：展示 `Overview`、已启用的资源标签页与 `AI`（`Settings` 通过顶部 `DashboardHeader` 齿轮按钮进入）。在设置中关闭某资源或隐藏 `AI` 入口会即时移除对应导航目的地，不破坏其余路径。

### 2.2 Overview 阅读层级

`Overview` 遵循固定的五级信息层级：

1. **System health**：`Healthy` / `Attention` / `Critical` / `Collecting`，不显示无法解释的 `0–100` 装饰性综合分数。
2. **资源决策摘要**：`CPU` 使用率、`Memory` 容量占用与压力状态、主磁盘容量占用、主网络接口可用性；每行可直接跳转到对应详情页。
3. **主趋势（Primary trend）**：`CPU` / `Memory` / `Network` 三选一，固定展示最近 60 秒真实样本。
4. **Attention**：仅展示最高优先级的可解释问题、实际测量值与 `Review` 入口；无问题时明确“无需操作”，必需信号未就绪时明确“正在收集”。
5. **Top processes**：真实进程名称、CPU 与内存列，支持按 CPU / Memory 排序。

### 2.3 核心与扩展模块语义

- **CPU**：当前总使用率与 `1m / 1h / 5h / 1d` 趋势、per-core 占用分布（识别“总体不高但单核饱和”）、简洁 load average 摘要、高占用进程排行，以及公开系统热状态上下文。
- **Memory**：以 macOS 事件驱动的 memory pressure 作为首要状态；容量占用趋势、Swap、compressed memory 与高内存进程作为次级解释，不把容量比例误称为压力。
- **Disk**：聚焦根挂载点 `/` 的 `used / free / total` 与容量趋势（`1h / 1d / 1w`），采用独立低频采样 cadence（默认 10 分钟，可选 1 小时 / 1 天）并明确标注“容量趋势 · 非磁盘 I/O”；其余挂载卷折叠在 `Advanced volumes`；提供 Trash-safe `DiskCleanup`（`Review Files…`）入口，先预览普通文件并由用户确认后再移入废纸篓。
- **Network**：聚焦系统默认路由所对应的主物理接口，展示下载 / 上传速率、双方向趋势（下载固定青色实线配柔和面积填充 `areaOpacity: 0.15`、上传固定琥珀/黄色实线 `areaOpacity: 0`，并通过 `NetworkSeriesLegend` 提供图例与 VoiceOver 方向语义 `"Download uses cyan solid; upload uses yellow solid"`）、`1m / 1h / 5h / 1d` 范围、可一键精确复制的 `Public IP`（默认关闭的 opt-in 查询）、`Primary private IP` 与 `MAC address`，以及折叠的 `Advanced interfaces`。
- **GPU / Battery / Thermal / AccessoryPower（V2 后扩展）**：
  - `GPU`：GPU 利用率与硬件状态趋势，配合热状态上下文。
  - `Battery`：电池电量、充放电功耗与健康信息，并集成 `AccessoryPower`（标准 HID / opt-in BLE 外设电量）。
  - `Thermal`：基于系统公开热状态通知（`ProcessInfo.thermalState`）的订阅驱动状态，纳入 `SystemHealthEvaluator` 评估，不构造虚假数值轮询。
- **Settings**：集中管理模块开关、实时刷新频率（`1 / 2 / 5 / 10` 秒 Picker）、磁盘容量采样间隔（`10m / 1h / 1d` Picker）、`Public IP` 开关、进程采集行数（`5–20` 步长 `5` Stepper）、登录启动及外观偏好（`System / Dark / Light`，已落地）。
- **AI Quota（Opt-in）**：面向 Claude 订阅的只读配额监控能力（`AIUsageProvider` / `ClaudeUsageProvider`）已落地，设计参见 [`lynxbar-ai-quota-and-opensource-plan.md`](./lynxbar-ai-quota-and-opensource-plan.md)。

---

## 3. 按需采样与生命周期（Demand-Driven Sampling）

LynxBar 通过 `MonitoringDemandCoordinator` 与 `MonitoringDemandBinding` 将 UI 可见性、菜单栏状态槽、常驻健康评估和临时修复预览解耦为引用计数式的按需采样驱动：

- **模块与页面分离**：`MonitoringModule`（采样单元，如 `.cpu`、`.memory`、`.disk`、`.network`、`.gpu`、`.battery`、`.process`、`.networkProcessAttribution`、`.thermal`、`.numericTemperature`、`.accessoryPower`、`.aiUsage`）与 `DashboardSection`（导航目的地）独立建模，避免单页切换触发无关的昂贵采样（例如仅在 `.network` 面板打开时才按需启用 `networkProcessAttribution`，`.aiUsage` 不在 `overviewHealthModules` 中且受 `aiUsageEnabled` 默认关闭门控）。
- **四类需求来源（`DemandReason`）**：
  - `.panel(DashboardSection)`：当前面板打开且可见的详情页；面板关闭后自动释放对应 token。
  - `.overviewHealth`：`Overview` 健康评估所需的常驻低开销信号（`[.cpu, .memory, .disk, .network, .thermal]`，不包含 `process` 或其他高成本轮询模块）。
  - `.menuBar`：菜单栏已启用状态槽所持有的长生命周期 lease token。
  - `.remediation(HealthIssueKind)`：修复动作预览与复测期间的临时采样。
- **生命周期约束**：
  - 仅由长生命周期宿主（如 `AppDelegate`、`PanelHost`、协调器对象）作为 `MonitoringDemandOwner` 持有 `DemandToken`，禁止短生命周期的 SwiftUI `View` 结构体直接持有或调用 `acquire`。
  - `startSampling()` 在需求 `0 → 1` 边沿触发并立即采集一次样本；`stopSampling()` 在 `1 → 0` 边沿触发，只停止新采样，不得清空已积累的有界历史或差值基线。

---

## 4. 指标口径与系统数据源（Metric Definitions & System Sources）

| 指标 | 定义 | 系统来源 | 明确不代表 |
| --- | --- | --- | --- |
| **CPU usage** | 相邻采样间 `PROCESSOR_CPU_LOAD_INFO` tick 增量中的非 idle 比例；总量与 per-core 同口径 | Mach `host_processor_info` | load average、温度 |
| **Load average** | 系统 1 / 5 / 15 分钟 runnable / load 摘要 | `getloadavg` | CPU 百分比 |
| **Memory capacity used** | `(active + wired + compressed) / hw.memsize` | `host_statistics64`、`host_page_size`、`hw.memsize` | macOS memory pressure |
| **Memory pressure** | 系统发布的 `normal / warning / critical` 事件；首次事件前为 `unknown` | `DispatchSource.makeMemoryPressureSource` | 自定义容量阈值 |
| **Swap** | 当前 `used / total` | `vm.swapusage` | 物理内存占用 |
| **Disk capacity** | 根挂载点 `/` 的 `total`、`available` 与 `used`（`used = total - available`） | `getmntinfo` 真实文件系统记录 | 吞吐、IOPS、读写延迟 |
| **Network rate** | 同一主接口相邻累计 byte counter 差值 / 实际采样间隔；接口切换时重建 baseline | `sysctl`（`IFMIB_IFDATA` / `ifmibdata`，64 位字节计数）+ `getifaddrs`（地址 / MAC / flags） | 所有接口总流量、网络质量 |
| **Primary interface** | 优先取默认 IPv4 路由的 `PrimaryInterface`；否则从 up、running、有地址的物理接口中按名称确定性选择 | `SystemConfiguration` + `getifaddrs` | 永远固定为 `en0` |
| **Public IP** | 默认关闭的 opt-in HTTPS 查询结果；失败时保留带标记的缓存或 `unavailable` | 公网 IP 查询端点 | 本地接口地址 |
| **Process CPU / memory** | `libproc` 采样的真实进程数据，名称优先映射运行中的 App 本地化名称 | `proc_listallpids`、`proc_pidinfo`、`NSRunningApplication` | 应用能耗或内核完整诊断 |

---

## 5. 健康评估与行动规则（System Health & Action Rules）

`SystemHealthEvaluator` 使用纯函数式的可测试规则集合评估系统状态，不计算 `0–100` 综合分。最终状态取所有触发问题中的最高 `HealthSeverity`（排序：`collecting < healthy < attention < critical`）；若必需信号未就绪且尚无问题，则返回 `collecting`。

| 信号 | Attention | Critical | 行动导向 |
| --- | --- | --- | --- |
| **CPU** | 最近 30 秒窗口（至少覆盖 27 秒）平均值 `≥ 85%` | 同窗口平均值 `≥ 95%` | 进入 CPU，检查趋势、per-core 分布与高 CPU 进程 |
| **Memory** | macOS 发布 `warning` | macOS 发布 `critical` | 进入 Memory，检查压力、Swap 与高内存进程 |
| **主磁盘剩余** | `≤ 15%` 或 `≤ 30 GB` | `≤ 5%` 或 `≤ 10 GB` | 进入 Disk，确认主卷剩余空间或启动 Trash-safe `DiskCleanup` |
| **主网络** | 已完成接口枚举但无主物理接口 | 无自动 Critical | 进入 Network，检查主接口与高级接口列表 |
| **系统热状态（Thermal）** | `ProcessInfo.thermalState` 为 `fair` 或 `serious` | `ProcessInfo.thermalState` 为 `critical` | 检查 CPU / GPU 负载与散热状态上下文 |

说明：阈值触发文案包含实际测量值或系统压力/热状态级别，并通过 `Review` 导航至对应详情页；Network 吞吐量没有“越高越坏”的通用方向，因此不参与健康 severity 判定。

---

## 6. 采样周期、有界历史与时间窗口（Cadence, Bounded History & Range Semantics）

### 6.1 采样与落盘策略

- **实时指标（CPU / Memory / Network / GPU / Battery / Process）**：遵循设置中的 `1 / 2 / 5 / 10` 秒实时 cadence；无效配置回落到 `2` 秒。
- **磁盘容量（Disk capacity）**：启动后立即采样，之后按独立设置的 `10 分钟 / 1 小时 / 1 天` cadence 运行（默认 `10 分钟`，不跟随秒级刷新）。切换 cadence 时取消当前等待、立即采样一次并重新计时；无效存储值回落到 `10 分钟`。
- **Public IP**：仅在显式开启时最多每 `600` 秒刷新一次；失败时保留缓存标注或返回 `unavailable`，不伪造数值。
- **历史持久化**：变更后去抖写入本地有界二进制归档（`history-v3.plist`，兼容从旧版 `history-v2.json` 迁移，原子写），应用正常终止或面板关闭时触发低成本 flush。

### 6.2 四层有界历史归档

| 层级 | 桶宽 | 保留期 | 服务范围 |
| --- | ---: | ---: | --- |
| **Live memory** | 原始真实样本 | 5 分钟（仅内存） | `1m` |
| **Archive A** | 15 秒平均桶 | 1 小时 | `1h` |
| **Archive B** | 1 分钟平均桶 | 5 小时 | `5h` |
| **Archive C** | 5 分钟平均桶 | 1 天 | `1d` |
| **Archive D** | 30 分钟平均桶 | 1 周 | `1w` |

每个持久化序列（CPU usage、Memory capacity used、Disk capacity used、Network download、Network upload 等）独立维护四层聚合与 retention 清理；秒级 live 样本不落盘，应用重启后 `1m` 视图从当前运行期重新 warm up。每个序列最多保留约 `1,164` 个持久桶，确保持久化文件体积长期有界。

### 6.3 时间范围与 Warm-Up 语义

- **可用范围**：`CPU / Memory / Network` 支持 `1m / 1h / 5h / 1d`；`Disk` 支持 `1h / 1d / 1w`；`Overview` 主趋势固定最近 60 秒。
- **严格时间边界**：查询严格基于 `[now - range.duration, now]` 的真实时间戳窗口，不按样本个数猜测时长，不插值、不回填未运行期间的数据。真实时间跨度覆盖不足目标范围 `90%` 时，界面明确显示 warming up 与实际 available duration。

---

## 7. 视觉系统、交互与辅助功能（Visual System, Interaction & Accessibility）

### 7.1 双外观语义视觉 Token（`Theme`）

- **动态色彩体系**：`Theme` 为所有表面（`surface` / `raised` / `raisedStrong`）、文本（`ink` / `secondaryInk` / `mutedInk`）、分割/悬浮/选中叠加（`divider` / `hoverFill` / `selectedFill`）、状态色（`health` / `warning` / `critical`）、CPU 分核阶梯与指标序列（`cpu`、`memory`、`disk`、`gpu`、`battery`、`networkInput`、`networkOutput`）提供 `light` / `dark` 双套 sRGB `NSColor` 动态 provider，随窗口 `effectiveAppearance` 自动解析，并在单元测试中校验 WCAG 2.1 对比度门槛。
- **空间与字体阶梯**：`Theme.Spacing`（`4 / 8 / 12 / 16`）、`Theme.Radius`（`7 / 10 / 12`）与基于 `SwiftUI.Font.system(_:design:)` 的 Dynamic Type 语义字阶（`title`、`title2`、`body`、`subheadline`、`caption`、`micro`、`metricValue`、`statValue`），支持系统文字大小缩放。
- **原生图标与防错边界**：统一使用 SF Symbols 与真实应用图标，不使用手绘 SVG 或 Web/CSS 替代界面；Network 曲线以青色实线配柔和面积填充（下载，`areaOpacity: 0.15`）与琥珀/黄色实线（上传，`areaOpacity: 0`）区分方向，并通过 `NetworkSeriesLegend` 暴露清晰的图例与 VoiceOver 标签（`"Download uses cyan solid; upload uses yellow solid"`；当前未实现 `differentiateWithoutColor` 线型切换）。

### 7.2 交互、命中区域与辅助功能契约

- **卡片与安全区**：`V2Card` 提供圆角容器外壳；标准内容通过 `V2InsetCardContent` 获得 `12pt` 横向、`8pt` 纵向安全区，防止标题贴边或数值裁切。
- **完整可见命中区域（`v2InteractiveSurface()`）**：自定义 `plain` button 在完成 frame 布局后统一声明 `contentShape(Rectangle())`，确保 tab、范围选择器、底部导航、健康行、行动行、进程行、复制按钮和折叠行整个可见背景均可点击，而非仅响应文字或图标本身。
- **Hover 与键盘焦点分离**：可交互行提供 `hoverFill` 反馈；`FocusState` 使用独立焦点环颜色（`Theme.focusRingColor(isSelected:)`），与选中态填充（`selectionSoft` / `selectedFill`）明确区隔。
- **精确剪贴板边界**：`ClipboardAction` 对空值拒绝写入，非空值逐字节写入 `NSPasteboard`，成功后展示限时反馈与明确 AX label。
- **诚实空状态与 AX 语义**：导航与范围选择器具备 `.isSelected` trait；折叠区明确暴露 `Expanded` / `Collapsed` AX value；所有采集前/异常/缓存场景诚实显示 `Collecting` / `Unavailable` / `Cached` / `Warming up`。

---

## 8. 代码模块映射（Module Mapping）

> 以下路径以应用源码根目录下的相对模块层级表示（`App/`、`Kit/`、`Providers/`、`Modules/`）。

| 能力域 | 主要实现路径 |
| --- | --- |
| **应用入口、状态栏与宿主面板** | `App/AppDelegate.swift`、`App/MenuBarStatusPresenter.swift`、`Kit/PanelHost.swift` |
| **面板框架与底部导航** | `Modules/Dashboard/DashboardView.swift` |
| **Overview / 健康评估 / Attention** | `Modules/Dashboard/OverviewView.swift`、`Kit/SystemHealth.swift` |
| **按需采样协调与路由映射** | `Kit/MonitoringDemand.swift`、`Kit/MonitoringDemandBinding.swift` |
| **双外观 Token 与 V2 基础组件** | `Kit/Theme.swift`、`Kit/V2Components.swift`、`Kit/Charts/`、`Kit/ContinuousChart.swift` |
| **有界历史、窗口与设置** | `Kit/MetricHistory.swift`、`Kit/RecentSampleWindow.swift`、`Kit/Settings.swift`、`Kit/Formatters.swift` |
| **精确剪贴板与修复上下文** | `Kit/ClipboardAction.swift`、`Kit/Remediation/`、`Providers/ProcessAction/` |
| **各资源详情与视图模型** | `Modules/CPU/`、`Modules/Memory/`、`Modules/Disk/`、`Modules/Network/`、`Modules/GPU/`、`Modules/Battery/`、`Modules/Process/`、`Modules/Thermal/`、`Modules/Settings/`、`Modules/About/` |
| **Trash-safe 磁盘安全清理** | `Modules/DiskCleanup/`、`Providers/DiskCleanup/` |
| **AI 订阅额度监控（Opt-in）** | `Providers/AIUsage/`、`Modules/AIUsage/` |
| **系统指标 Providers** | `Providers/CPUProvider.swift`、`Providers/MemoryProvider.swift`、`Providers/DiskProvider.swift`、`Providers/NetworkProvider.swift`、`Providers/NetworkProcessProvider.swift`、`Providers/GPUProvider.swift`、`Providers/BatteryProvider.swift`、`Providers/ProcessProvider.swift`、`Providers/Thermal/`、`Providers/AccessoryPower/` |

---

## 9. 设计权衡与已知约束（Tradeoffs & Known Constraints）

1. **应用关闭期间不采集**：应用定位为纯前端菜单栏工具，不驻留后台 daemon；`1w` 与 `1d` 视图仅反映应用实际运行期积累的聚合桶，不代表连续内核遥测。
2. **主接口与主卷聚焦**：`Overview` 与主指标聚焦系统默认路由的 IPv4 主物理接口及根挂载点 `/`，避免虚拟网卡、APFS 共享容器与外置磁盘造成的重复计数误导；高级明细收拢至折叠列表。
3. **1 天 Disk cadence 的稀疏性**：选择低频 `1 天` 磁盘容量轮询可把采样成本降至最低，但短时间窗口（`1h` / `1d`）会诚实处于 warm-up 或稀疏样本状态，不会通过插值制造连续曲线。
4. **300 秒（5 分钟）持久化去抖**：历史归档采用 300 秒（5 分钟）去抖写盘与退出/关闭面板 flush 的折中方案，在降低磁盘 I/O 与减少异常退出丢失之间取得平衡。
5. **Public IP 依赖外部网络**：该功能默认关闭（opt-in）；启用后受限于外部 HTTPS 服务与本机连通性，不可达时严格区分为 `Cached` 或 `Unavailable`。
