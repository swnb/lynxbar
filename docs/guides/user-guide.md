# LynxBar User Guide

> **Related**: [English README](../../README.md) · [简体中文 README](../../README.zh-CN.md) · [Security Policy](../../SECURITY.md)

This guide walks through **LynxBar**'s menu bar modes, monitoring tabs, Trash-safe disk cleanup, opt-in Claude subscription quota setup, and privacy/appearance controls, including exact English and Simplified Chinese (`简体中文`) UI labels.

---

## 1. Menu Bar & `420×600` Panel Overview

LynxBar runs as a menu bar agent (`LSUIElement`) with no Dock icon.

- **Left-click** the menu bar item to open the `420×600` dashboard panel.
- **Right-click** the menu bar item for quick actions (`About LynxBar` / `关于 LynxBar`, `Quit LynxBar` / `退出 LynxBar`).
- **Header (`42pt`)**: Displays `LynxBar`, your Mac's name, `Live` status, and the **Settings** gear button (`⚙`).
- **Bottom Navigation (`62pt`)**: Switch between `Overview` (`概览`), enabled hardware tabs, and `AI` (`AI` / `AI 额度`).

### Menu Bar Display Modes (`Settings` → `Menu bar` / `设置` → `菜单栏`)
Choose one of three **Display mode** (`显示模式`) options:
- **Minimal** (`精简`): System health indicator only.
- **Focus** (`单项`): Displays 1 selected metric slot.
- **Compact** (`紧凑`): Displays up to 3 metric slots (defaults to `CPU`, `DSK`, `NET`).

### Available Menu Bar Metric Slots
| Short Label | English Name | 简体中文 | Notes |
| --- | --- | --- | --- |
| `CPU` | CPU | CPU | Total CPU usage |
| `MEM` | Memory | 内存 | Memory capacity / pressure summary |
| `DSK` | Disk usage | 磁盘占用 | Root volume (`/`) capacity usage |
| `NET` | Network ↓/↑ | 网络 ↓/↑ | Primary interface download/upload throughput |
| `GPU` | GPU | GPU | GPU utilization on supported hardware |
| `TMP` | System thermal state | 系统热状态 | Public `ProcessInfo.thermalState` status |
| `BAT` | Internal battery | 内置电池 | MacBook battery percentage |
| `ACC` | Accessory battery | 外设电量 | `GameController` & opt-in BLE accessories |
| `AI` | AI Quota | AI 额度 | Claude 5h quota (`AI 78%`), or `AI —` when off/unavailable/stale (`15m` TTL) |

---

## 2. System Monitoring Tabs

- **Overview (`概览`)**: Shows system health (`Healthy` / `Attention` / `Critical` / `Collecting`), resource summary rows, a 60-second primary trend (`CPU`, `Memory`, or `Network`), the top actionable `Attention` item, top 3 processes, and a compact **AI Quota** row when Claude quota monitoring is enabled.
- **CPU**: Per-core bars, `1m / 5m / 15m` load averages, uptime, thermal context, and top CPU processes.
- **Memory (`内存`)**: Event-driven macOS memory pressure (`Normal` / `Warning` / `Critical`), active/wired/compressed breakdown, swap usage, and top memory processes.
- **Disk (`磁盘`)**: Root volume (`/`) usage, capacity trend (`1h` / `1d` / `1w` ranges sampled every `10 min`, `1 hour`, or `1 day`), mounted volumes under `Advanced volumes`, and **Review Files…** (`检查文件…`).
- **Network (`网络`)**: Default-route primary physical interface, live download/upload charts, on-demand per-process attribution (`nettop`), primary private IP, MAC address, and opt-in Public IP.
- **GPU**: Metal device details and GPU utilization trends.
- **Battery (`电池`)**: Internal battery status and `Accessory batteries` (`外设电量`).

To hide unused tabs from the bottom bar without stopping Overview health checks or menu bar slots, toggle them under **Settings → Visible destinations** (`设置` → `可见目的地`).

---

## 3. Trash-Safe Disk Cleanup (`Free Up Space Safely` / `安全释放空间`)

1. Open the **Disk** (`磁盘`) tab and click **Review Files…** (`检查文件…`).
2. In the **LynxBar — Free Up Space Safely** window, click **Scan Downloads** (`扫描下载文件夹`) or **Choose Folder…** (`选择文件夹…`).
   - **Safety boundaries**: LynxBar automatically refuses volume roots, your home directory (`~`), `~/Library` and its subfolders, symbolic links, `.app` bundles/packages, and non-local volumes.
   - **Candidate rules**: Only non-hidden, downloaded regular local files with hard-link count `1` that are either **Large** (`≥ 1 GiB`) or **Old large** (`≥ 100 MiB` and unmodified for `≥ 90` days) appear.
3. Review candidates using the **All / Large / Old** filters and **Show in Finder**. Zero files are preselected.
4. Check only the files you want to remove, click **Move Selected to Trash** (`将所选项目移入废纸篓`), and confirm the dialog.
   - Files are **moved to macOS Trash**, never permanently deleted. Disk space is reclaimed once you empty Trash in Finder.

---

## 4. Claude Subscription Quota (`AI Quota` / `AI 额度`)

Claude subscription quota tracking is **off by default** and never makes network requests unless you enable it.

### Enabling & First-Time Keychain Prompt
1. Open the **AI** tab and click **Enable Claude Quota Monitoring** (`启用 Claude 额度监控`), **or** go to **Settings → Privacy** (`设置` → `隐私`) and turn on **Claude subscription quota** (`Claude 订阅额度`).
2. On first read, macOS may show a one-time system dialog asking to allow read access to the Keychain item `"Claude Code-credentials"`.
   - LynxBar reads Keychain **read-only** and skips MCP-only entries lacking `claudeAiOauth.accessToken`.
   - If no OAuth token is in Keychain (or you decline), LynxBar checks `~/.claude/.credentials.json` read-only.
   - LynxBar never accesses browser cookies, stores passwords, or silently runs CLI commands.

### Reading Your Quota & Switching Display Style
- **5-hour session (`5 小时会话`)** & **7-day weekly (`7 天每周`)**: Shows progress bars colored by remaining headroom (green `> 30%`, amber `10%–30%`, red `≤ 10%`) and exact reset countdowns.
- **Model breakdown (`分模型额度`) & Extra usage (`超额花费`)**: Shown automatically when returned by Anthropic (`Sonnet 7-day`, `Opus 7-day`, `OAuth apps 7-day`, `Cowork 7-day`, or active pay-as-you-go overage).
- **Remaining vs. Used Percentage**: Go to **Settings → Privacy → Quota display** (`设置` → `隐私` → `额度显示口径`) to switch between **Remaining quota** (`剩余额度`, default, e.g., `78% left`) and **Used quota** (`已用额度`, e.g., `22% used`).
- **Hiding the AI Tab**: Toggle **AI Quota** off under **Settings → Visible destinations** (`可见目的地`) if you prefer a hardware-only dashboard.

### Troubleshooting (`claude /login` & Rate Limits)
- **`Claude Code credentials not found` / `Claude session expired`**:
  Run the following command in Terminal to sign in or refresh your OAuth session, then click **Retry** (`重试`) in LynxBar:
  ```sh
  claude /login
  ```
- **Keychain authorization denied**: If you clicked Deny on the Keychain prompt and `~/.claude/.credentials.json` is absent, LynxBar stops automatic retries so macOS will not repeatedly prompt you. Re-authenticate via `claude /login` or click **Retry** after granting read access.
- **Rate limited (`429`)**: LynxBar retains your last valid snapshot with a status banner and backs off automatically.

> **Disclaimer**: Claude quota monitoring queries `https://api.anthropic.com/api/oauth/usage`, an unofficial endpoint used by Claude Code. LynxBar is an independent project with no affiliation with Anthropic.

---

## 5. Privacy & Appearance Settings

Open **Settings** (`⚙` in the top-right header) to configure:
- **Appearance (`外观`, under `General` / `通用`)**: **System** (`跟随系统`, default), **Dark** (`深色`), or **Light** (`浅色`).
- **Show public IP (`显示公网 IP`, under `Privacy` / `隐私`)**: Off by default. When enabled, queries `ipify`, `ifconfig.me`, or `icanhazip` over HTTPS every 10 minutes.
- **Standard Bluetooth battery service (`标准蓝牙电量服务`, under `Accessory battery` / `外设电量`)**: Off by default. Scans standard BLE Battery Service (`180F` / `2A19`) only while accessory battery data has active demand.
- **Launch at login (`开机启动`, under `General` / `通用`)**: Uses macOS `SMAppService`.
- **Bounded Local History (`历史`)**: Stores up to 1 week of aggregate buckets locally in `~/Library/Application Support/LynxBar/history-v3.plist` with zero cloud sync.
