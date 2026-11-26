# LynxBar User Guide

> **Related**: [English README](../../README.md) · [简体中文 README](../../README.zh-CN.md) · [Security Policy](../../SECURITY.md)

This guide walks through **LynxBar**'s menu bar modes, monitoring tabs, Trash-safe disk cleanup, opt-in AI subscription quota setup (Claude, OpenAI Codex, and Gemini), and privacy/appearance controls, including exact English and Simplified Chinese (`简体中文`) UI labels.

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
| `AI` | AI Quota | AI 额度 | Most-constrained active AI quota (`AI 78%`), or `AI —` when off/unavailable/stale (`15m` TTL) |

---

## 2. System Monitoring Tabs

- **Overview (`概览`)**: Shows system health (`Healthy` / `Attention` / `Critical` / `Collecting`), resource summary rows, a 60-second primary trend (`CPU`, `Memory`, or `Network`), the top actionable `Attention` item, top 3 processes, and a compact **AI Quota** row when one or more AI quota providers are enabled.
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

## 4. AI Subscription Quota (`AI Quota` / `AI 额度`)

AI subscription quota tracking for **Claude**, **OpenAI Codex**, and **Antigravity** (powered by `CodexBarCore` under the MIT license) is **off by default** and never reads credentials or makes network requests unless you explicitly enable each provider.

### Enabling & Local Non-Cookie Sources
1. Open the **AI** tab and toggle on the providers you want (**Claude**, **OpenAI Codex**, **Antigravity**), **or** go to **Settings → Privacy** (`设置` → `隐私`) to enable them individually.
2. Each provider uses non-cookie local sources via `CodexBarCore` (`cookieSource = .off`, never storing passwords or writing to local credential stores):
   - **Claude**: OAuth-only via macOS Keychain item `"Claude Code-credentials"` or `~/.claude/.credentials.json`. On first read, macOS may show a one-time Keychain read prompt.
   - **OpenAI Codex**: Reads `$CODEX_HOME/auth.json` (when `CODEX_HOME` is set) or `~/.codex/auth.json`.
   - **Antigravity**: Queries your local Antigravity desktop app, IDE, or `agy` CLI session (replacing the sunset consumer Gemini CLI).

### Reading Your Quotas, Multi-Provider Overview & Display Style
- **Multi-Entry AI Tab**: Each enabled provider renders its own card with plan/account badges, per-provider refresh, rolling or model quota windows (`5-hour session`, `7-day weekly`, `Code Review`, `Gemini Models`, `Claude and GPT`, model-specific breakdowns), **Extra usage** (Claude), **Credits** (Codex), and reset countdowns colored by remaining headroom (green `> 30%`, amber `10%–30%`, red `≤ 10%`).
- **Compact `Overview` Row & `AI` Menu Bar Slot**:
  - In `Overview`, 1–3 enabled providers fit inside the fixed `36pt` summary row (`420×600` layout budget preserved).
  - In the menu bar `AI` slot, LynxBar displays the most-constrained fresh provider's percentage (e.g., `AI 78%`) within the `132pt` Focus / `300pt` Compact width budgets, lists every active provider and percentage in the VoiceOver label/tooltip, and falls back to `AI —` when all enabled providers are off, errored without fresh data, or past the `15m` TTL.
- **Remaining vs. Used Percentage**: Switch directly in the AI panel footer (`Left` / `Used` / `剩余` / `已用`) or under **Settings → Privacy → Quota display** (`设置` → `隐私` → `额度显示口径` — **Remaining quota** / `剩余额度` vs. **Used quota** / `已用额度`).
- **Hiding the AI Tab**: Toggle **AI Quota** off under **Settings → Visible destinations** (`可见目的地`) if you prefer a hardware-only dashboard.

### Troubleshooting (`claude /login`, `codex login`, `agy login`, & Rate Limits)
- **Missing or expired credentials**: Run the corresponding CLI command in Terminal to sign in or refresh your local session (or launch Antigravity), then click **Retry** (`重试`) on that provider's card:
  - Claude: `claude /login`
  - OpenAI Codex: `codex login`
  - Antigravity: `agy login`
- **Keychain authorization denied (Claude)**: If you clicked Deny on the Keychain prompt and `~/.claude/.credentials.json` is absent, LynxBar stops automatic retries so macOS will not repeatedly prompt you. Re-authenticate via `claude /login` or click **Retry** after granting read access.
- **Rate limited (`429`)**: LynxBar retains the affected provider's last valid snapshot with a per-card status banner and backs off automatically without disturbing sibling providers.

> **Disclaimer**: AI quota monitoring queries non-public endpoints used by local CLI tools (`api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`, `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` & `:retrieveUserQuota`). LynxBar is an independent project with no affiliation with Anthropic, OpenAI, or Google.

---

## 5. Privacy & Appearance Settings

Open **Settings** (`⚙` in the top-right header) to configure:
- **Appearance (`外观`, under `General` / `通用`)**: **System** (`跟随系统`, default), **Dark** (`深色`), or **Light** (`浅色`).
- **Show public IP (`显示公网 IP`, under `Privacy` / `隐私`)**: Off by default. When enabled, queries `ipify`, `ifconfig.me`, or `icanhazip` over HTTPS every 10 minutes.
- **Standard Bluetooth battery service (`标准蓝牙电量服务`, under `Accessory battery` / `外设电量`)**: Off by default. Scans standard BLE Battery Service (`180F` / `2A19`) only while accessory battery data has active demand.
- **Launch at login (`开机启动`, under `General` / `通用`)**: Uses macOS `SMAppService`.
- **Bounded Local History (`历史`)**: Stores up to 1 week of aggregate buckets locally in `~/Library/Application Support/LynxBar/history-v3.plist` with zero cloud sync.
