# Hermes TouchBar — 设计方案

> macOS 菜单栏常驻 App，将 Hermes Agent 的运行状态实时映射到 Touch Bar。
> 目标硬件：MacBookPro16,1（2019 16 寸 Intel，带 Touch Bar）。
> 当前版本：`0.2.0`（重构中）

---

## 0. 修订记录

| 日期 | 版本 | 主要变更 |
|---|---|---|
| 2026-09-15 | 0.1.0 | 初版，裸文件系统 poll 实现 |
| 2026-09-15 | 0.2.0 | 重写：引入 Hermes IPC 协议作为主数据通道；修补 9 项 Tier-1 bug；引入三层架构 |
| 2026-09-16 | 0.2.0 | 实机修复 8 项：pill 等宽、picker 读 tui、S pill 标题、model 双路径闪烁、approval 文件桥接、状态恒 ready 根因、ctx 口径、待审批文字闪烁；落地差异见 §14 |

---

## 1. 设计目标

| 维度 | 目标 |
|---|---|
| 可见性 | 用户在任意前台 app 都能瞥到 Touch Bar 顶部一行 Hermes 状态 |
| 不侵入 | 不抢占系统控制条（亮度/音量/媒体），不弹通知骚扰 |
| 状态保真 | 9 状态覆盖 Hermes 全部活动场景，**刷新 ≤ 1.5s，且与 Hermes 内部状态语义一致** |
| 皮肤一致 | 与 `hermes skin use <name>` 同步配色，1s 内热切换，**builtin 切到对应调色板而非回退 default** |
| 交互轻量 | 4 个快捷键按钮（打开 TUI / 新会话 / 审批通过 / 取消） |
| 可分发 | 命令行出 `.app`，ad-hoc 签名 |
| **可维护性** | **Hermes 升级时 schema 变化以版本号 + 解析失败告警处理，不能静默错** |

---

## 2. 状态机

9 个状态定义如下。**状态本身由 Hermes 端告诉我们**，本项目仅做时间窗内的退化判定（fallback），不再扫 `(Y/n)` 这种启发式。

| 状态 | 触发 | 颜色键 | 按钮 1 文字 | 按钮 1 emoji |
|---|---|---|---|---|
| `idle` | 无 active session、gateway 在 | `status_bar_dim` | 空闲 | ◌ |
| `ready` | 当前 TUI/CLI 在线、待输入 | `status_bar_text` | 准备中 | ◉ |
| `thinking` | Hermes 报告 `state=thinking` 或最近 assistant 在 `workingWindow` 内且 `reasoning_tokens` 增长 | `ui_thinking` | 思考中 | ∿ |
| `working` | Hermes 报告 `state=working` 或最近 assistant 在 `workingWindow` 内且 `tool_calls` 非空 | `ui_tool` | 工作中 | ⚙ |
| `streaming` | Hermes 报告 `state=streaming` 或最近 assistant `finish_reason IS NULL` 且在 `streamingWindow` 内 | `ui_accent` | 输出中 | ▸ |
| `waitingApproval` | Hermes 流中 `approval_pending=true` | `status_bar_warn` | 待审批 | ⏸ |
| `ok` | Hermes 报告 `state=ok` 或最近 12s 内 `finish_reason = stop` 且无后续 | `status_bar_good` | 完成 | ✓ |
| `error` | Hermes 报告 `state=error` 或最近 30s 内有 `finish_reason = error` 或 tool 抛错 | `ui_error` | 失败 | ✗ |
| `gatewayDown` | `gateway.up=false` 或 Hermes 流断流 ≥ 5s | `ui_error` | 网关断 | ⚠ |

**优先级**：`gatewayDown` > `waitingApproval` > `error` > `working/thinking/streaming/ok` > `ready` > `idle`。Hermes 直接给的 `state` 是首要判定；时间窗退化只在 Hermes 流掉线 / 没有该字段时使用。

阈值（仅作 fallback 用，可在 `StateMachine` 顶部调整）：

```swift
workingWindow    = 5s   // thinking / working 判定
streamingWindow  = 8s   // streaming 退化
okWindow         = 12s  // ok 退化
errorWindow      = 30s  // error 退化
cronWindow       = 10s  // cron-fired 退化（仅 fallback）
streamStaleWindow = 5s  // Hermes 流断流后强制 gatewayDown
```

---

## 3. Touch Bar 按钮布局（8 个）

```
[1 状态图标] [2 状态文字] | [3 进度条 ctx%] [4 模型名] [5 session] | [6 皮肤] [7 TUI] [8 新会话]
```

- 按钮 1、2 改用 `NSTextField(isEditable=false)` 而非 `NSButton`，修 a11y 与 hit-test 问题。
- 按钮 3 用 `NSProgressIndicator` 走 intrinsic size，不再硬编码 frame。
- 按钮 4、5 只读，用 `NSTextField`。
- 按钮 6、7、8 可点，背景色由皮肤决定。

---

## 4. 数据采集 ⭐（重构主战场）

### 4.1 数据源优先级

启动时按下列顺序探测，**首次成功即绑定**：

1. **`hermes status --json --watch`**（首选）— `Process` 启动 + `Pipe` 拿 stdout，按行解析为 `HermesStatus` JSON 流。Schema 见 §4.2。
2. **`hermes status --json`**（降级）— 一次性 JSON 输出；本项目自行按 1.5s 定时轮询。用于 Hermes 还没支持 `--watch` 的版本。
3. **SQLite reader**（最末）— 打开 `~/.hermes/state.db` 只读模式，参照 schema v1 解析。**仅在前两项都不可用时启用**，并在 console 打印 WARNING 让用户知道 Hermes 应该升级了。

### 4.2 Hermes 协议 schema（v1）

```jsonc
{
  "v": 1,                              // 协议版本
  "ts": "2026-09-15T10:00:00.123Z",    // 服务端时间戳（ISO8601 with fractional）

  "gateway": {
    "up": true,                        // 网关在
    "pid": 12345,                      // 主进程 PID（debug 用）
    "version": "0.3.1",                // Hermes 版本
    "started_at": "2026-09-15T08:00:00Z"
  },

  "session": null | {
    "id": "abc123",                    // 活跃 session id
    "source": "tui" | "cli" | "cron" | "api",
    "model": "claude-sonnet-5",
    "provider": "anthropic",
    "context": {
      "tokens": 45000,
      "max": 200000
    },
    "last": {
      "assistant_at": "2026-09-15T09:59:58Z",
      "user_at":      "2026-09-15T09:59:50Z",
      "tool_at":      "2026-09-15T09:59:55Z",
      "reasoning_at": "2026-09-15T09:59:57Z",
      "finish_reason": "stop" | "error" | null
    }
  },

  "state": "thinking" | "working" | "streaming" | "ok" | "error"
         | "ready" | "idle" | "waiting_approval",   // Hermes 端权威判定

  "approval": null | {
    "pending": true,
    "prompt": "(Y/n)",
    "tool": "shell_exec",
    "args": "rm -rf node_modules"
  },

  "cron": {
    "last_fired_at": "2026-09-15T09:00:00Z" | null,
    "recent_job_id": "morning-news" | null
  },

  "skin": "slate"                      // 当前激活皮肤
}
```

**关键变化**：
- `state` 字段由 Hermes 权威给出，本项目不再做启发式推断。`StateMachine` 在 Hermes 流正常时只做透传 + 颜色键映射。
- `approval` 取代 `(Y/n)` 字符串扫描；`approval_pending=true` 直接驱动 `waitingApproval` 状态。
- `cron.last_fired_at` 取代 `cron/jobs.json` mtime 启发式。
- `skin` 取代我们自己解析 `config.yaml`。

### 4.3 解析与容错

- JSON 解码失败（schema 版本对不上、字段缺失）→ 不 crash；丢弃该帧 + `console.log` 一条 warning；UI 保持上一帧。
- 流断流（stdin EOF 或 5s 内无新行）→ 触发 `gatewayDown`，尝试 30s 后重连。
- 字段值超出 enum 范围 → 当作 unknown，本项目用 `idle` 显示，不打断 UI。

### 4.4 回退：SQLite reader（schema v1）

仅在 §4.1 第 3 项启用，且 `state.db` 必须存在一张 `_meta` 表记录 `schema_version`，否则拒绝读取并提示用户升级 Hermes。

```sql
CREATE TABLE _meta (schema_version INTEGER PRIMARY KEY, value TEXT);
-- 启动时 SELECT value FROM _meta WHERE schema_version = 1;
```

读到的列：`sessions(id, source, model, started_at, input_tokens, output_tokens)`、`messages(session_id, role, timestamp, tool_name, finish_reason, reasoning, reasoning_content, active, compacted)`。Hermes 一旦改变这些列，reader 必须同步改；通过 CI 跑一个 hermes 端 fixture 数据库做冒烟。

---

## 5. 皮肤对接

### 5.1 builtin 调色板（9 个）

每个 builtin 必须在代码里有真实色板，**不再回退到 `default`**：

| name | 主题 |
|---|---|
| `default` | 经典 Hermes — gold and kawaii |
| `ares` | 红色烈焰 |
| `mono` | 单色灰阶 |
| `slate` | 冷蓝开发者（见 `skin/slate.example.yaml`） |
| `daylight` | 明亮日间 |
| `warm-lightmode` | 暖色 light |
| `poseidon` | 深蓝海洋 |
| `sisyphus` | 岩石灰 |
| `charizard` | 橙红龙 |

每个 builtin 在 `SkinProvider.swift` 里以 `static let` 常量定义（参考 `HermesSkin.default`）。

### 5.2 用户 YAML

- 路径：`~/.hermes/skins/<name>.yaml`
- schema：`name` / `description` / `colors`（必填）、`branding.agent_name`（可选）
- 缺键回退 builtin `default`，**不再回退到任一其它 builtin**
- `SkinProvider` 监听目录改动（`DispatchSource` on `O_EVTONLY` fd），200ms 防抖后 reload

### 5.3 切换流程

1. 用户在 Touch Bar 按 `[6 皮肤]` 按钮或菜单项「下一皮肤」→ `SkinProvider.cycleNext()`
2. builtin：从 `builtin` 表中按固定顺序取下一个
3. 用户自定义：按字典序
4. 切换时 Hermes 流里的 `skin` 字段若不一致，本项目以本地的 `cycleNext` 为准（用户主动行为）；同时向 Hermes 发 `hermes skin use <name>` 的等价调用，确保两边一致（如果 Hermes 提供此 RPC；否则仅本地生效并在 console 提示）

### 5.4 颜色键（本项目用到的）

只需要以下 10 个，多余的键不进 builtin 表也不强求用户填：

```
ui_accent, ui_ok, ui_error, ui_warn, ui_tool, ui_thinking,
status_bar_text, status_bar_dim, status_bar_good, status_bar_warn
```

---

## 6. 常驻显示方案

1. App 启动后注册 `LSUIElement=true` 隐藏 Dock 图标（保留在 `Info.plist`）
2. `PersistentTouchBarAPI.installTrayIcon` 把 `TrayBadgeView` 挂到系统控制条
3. `PersistentTouchBarAPI.present` 把完整 `NSTouchBar` 挂到控制条上方
4. macOS 系统控制条始终保留（亮度/音量/Siri 不被吞）
5. **modal 自动隐藏后**：tray badge 仍在，用户点击 badge → `present()` 重新挂 modal
6. **skin 切换后**：调 `reload()` 触发 `update()` + 重新 `present()`，避免 macOS 缓存旧 item set

---

## 7. 快捷键

- `⌃⌥⌘H` 打开 Hermes TUI
- `⌃⌥⌘N` 新会话（`hermes chat --new`）
- `⌃⌥⌘A` 审批通过
- `⌃⌥⌘X` 取消（`Ctrl-C`）

实现：`Carbon.RegisterEventHotKey`，OSType `'HERM'`。**handler 必须校验事件 OSType 匹配自己的 signature**，避免多套 hotkey 套件串扰。

approve / cancel 通过 `osascript -e 'tell app "System Events" to keystroke ...'`，需要用户给本 app 辅助功能权限。**首次启动时弹一次引导**（不弹通知，弹一个置顶菜单项，附链接到 System Settings → Privacy → Accessibility）。

---

## 8. 项目边界

| 包含 | 不包含 |
|---|---|
| Touch Bar 装配 + 9 状态 + 8 按钮 + 皮肤热切换 + 4 快捷键 | 抢所有 app 的系统 Touch Bar 之外的位置 |
| `hermes status --json --watch` 主通道 + SQLite 兜底 | 监听 state.db 实时 WAL tail（用 mtime/CLI 流足够） |
| 命令行 `xcodebuild` / `scripts/build.sh` 出 `.app` | 打包成 .dmg 上网分发 |
| Ad-hoc 签名 | 开发者 ID 签名 + 公证 |
| builtin 调色板内置 + 用户 YAML 加载 | Hermes 端皮肤热同步 RPC（v0.2 不做，v0.3 议） |

---

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| macOS 15 已弱化 NSTouchBar，但 API 仍编译运行 | 锁定 deployment target = 13.0；用 NSTouchBar 公共 API |
| Apple Silicon 不在范围 | x86_64 only |
| Hermes 改 schema 我们没跟上 | 协议带 `v` 字段；解析失败丢弃并 warn；不 crash |
| Hermes 流断流 | 5s 无新行 → `gatewayDown`；30s 后自动重连 |
| SQLite reader 启动时 Hermes 未跑 | 显示 `gatewayDown` 而非 crash |
| 用户改 skin 名 | builtin 表 + 任意 user.yaml 都能解析；解析失败回退 `default` builtin（不是 user skin） |
| 辅助功能权限缺失 | 首次启动引导菜单项 |
| 私有 API 在未来 macOS 失效 | 集中在 `TouchBarPrivate/` 一个目录；切换路径只需改这个目录 |

---

## 10. 架构分层

三层严格单向依赖，`HermesStatus`（`Codable` struct，versioned）是唯一跨层契约：

```
┌──────────────────────────────────────────────┐
│  UI（@MainActor）                            │
│  - AppDelegate                                │
│  - TouchBarController                         │
│  - MenuBar (NSStatusItem)                     │
│                                              │
│  订阅 AsyncStream<RenderSnapshot>             │
└──────────────────┬───────────────────────────┘
                   │
┌──────────────────▼───────────────────────────┐
│  Domain（Pure-ish）                          │
│  - StateMachine.evaluate(HermesStatus)       │
│    → HermesState                             │
│  - SkinProvider (color lookup, cycle)         │
│                                              │
│  无 I/O；纯函数 + 静态表                      │
└──────────────────┬───────────────────────────┘
                   │
┌──────────────────▼───────────────────────────┐
│  DataSource（Background queue）              │
│  - HermesStreamSource (Process + JSON-lines)  │
│  - HermesPollSource   (Process + 1.5s loop)  │
│  - SQLiteSource       (read-only, mtime)     │
│                                              │
│  产出 AsyncStream<HermesStatus>              │
└──────────────────────────────────────────────┘
```

### 10.1 跨层契约 `HermesStatus`

```swift
struct HermesStatus: Codable {
    let v: Int                                  // schema 版本
    let ts: Date
    let gateway: GatewayInfo
    let session: SessionInfo?
    let state: HermesRawState?                   // Hermes 给的 state
    let approval: ApprovalInfo?
    let cron: CronInfo
    let skin: String?
}

enum HermesRawState: String, Codable {
    case idle, ready, thinking, working, streaming
    case waitingApproval = "waiting_approval"
    case ok, error
}
```

### 10.2 StateMachine 职责调整

- **新**：Hermes 流正常时 `state = hermes.state`，仅做颜色键映射
- **保留**（fallback）：当 Hermes 流断流 / `state=null` 时，用时间窗退化判定
- **永远**：gateway 字段为 `false` → 强制 `gatewayDown` 覆盖

### 10.3 单 timer 原则

只 `AppDelegate` 持有一个 1.5s timer（或者 `DispatchSourceTimer`），所有 reader 把 HermesStatus 推到 `AsyncStream`，UI 订阅 stream。**`StatusReader` 不再自建 timer**。

---

## 11. 重构路线图（按 ROI 排序）

### Tier A — 数据通道切到 Hermes CLI 流 ✅ 必做
- 与 Hermes 团队对齐 `hermes status --json --watch` 输出 schema（见 §4.2）
- 在本项目加 `HermesStreamSource` actor
- `HermesStatus` 加 `v` 字段、protocol-aware decoder
- 老的 SQLite reader 暂留为兜底，但 page 1 改成显式「Hermes 太旧，请升级」提示

### Tier B — UI 与数据流解耦 ✅ 必做
- 引入 `AsyncStream<HermesStatus>` 从 DataSource 推到 AppDelegate
- `StatusReader` 删自己的 timer，改为被动函数 `refresh() -> HermesStatus`
- 主线程不再做 I/O

### Tier C — builtin 皮肤补齐 ✅ 必做
- 8 个 builtin 各写一个 `static let`
- `setActive` 查 builtin 表，回退仅在用户 YAML 解析失败时
- 单元测试覆盖 cycle 顺序

### Tier D — 修 9 项 Tier-1 bug ✅ 必做
1. `HermesStatus.empty` 改成 `static func empty(now:)`
2. `checkApproval` 删除（改用 Hermes `approval_pending`）
3. `lastErrorMessage` 直接返回 `Date?`
4. `readConfigModel` 删除（改用 Hermes 流 `session.model`）
5. `checkGateway` / `checkCronFired` 删除（改用 Hermes 流）
6. Touch Bar read-only 项从 `NSButton` 改 `NSTextField`
7. `NSProgressIndicator` 改 intrinsic size
8. Carbon handler 校验 OSType
9. `reload()` 后强制 `present()`（已实现，确认）

### Tier E — 单元测试 ⚠️ 应做
- 加 `HermesTouchBarTests` target
- 覆盖 `StateMachine` 全部 9 状态边界
- 覆盖 `SkinProvider.cycleNext` 与 builtin 回退
- 覆盖 `HermesStatus` decoder 各 version

### Tier F — 三层彻底拆分 ⏳ 可选
- 把 Domain 层抽成独立 Swift Package
- 让 DataSource 可被 mock，UI 跑 snapshot 测试
- 留到 v0.3

---

## 12. 测试策略

- **单元测试**：`StateMachine`、`SkinProvider`、`HermesStatus` decoder。CI 必跑。
- **集成测试**：起一个 mock Hermes 进程，往 stdout 写 JSON-lines，验证本项目 UI 收到正确的 `HermesState`。手工跑。
- **手动冒烟**：Hermes 真起一次，1) 让 agent 跑 2) 触发 (Y/n) 审批 3) 切皮肤 4) 杀网关。每个 case 验证 Touch Bar 表现。

---

## 13. 版本目标

| 版本 | 内容 |
|---|---|
| 0.2.0 | Tier A + B + C + D + E 全部完成，部署到本机 |
| 0.3.0 | Tier F + 与 Hermes 团队的 skin RPC 同步 + Apple Silicon build |

---

## 14. 2026-09-16 落地增量（对齐实际实现）

设计初稿的若干假设在实机验证中被修正/落地，记录于此以对齐文档与代码。**历史章节（§1-§13）保留为设计过程记录，不代表当前代码**。

| # | 主题 | 设计与实际的差异 |
|---|---|---|
| 14.1 | 数据通道 | §4.1 首选 `hermes status --json --watch` **未采用**；实际是 `HermesPythonSource` spawn 长跑 Python（`hermes_source.py`），in-process introspection `~/.hermes/hermes-agent`，0.5s 一帧 JSON-lines。实际 v1 schema 字段：`gateway / session / sessions / session_count / state(null) / approval / cron / context_tokens / context_max / skin / recent_messages`（与 §4.2 设计稿不同） |
| 14.2 | 状态数据源（新问题 6） | `SessionDB.get_messages()` 默认按插入序取**最旧**消息；不传 `latest=True` 时 `limit=5` 拿到最早 5 条 → 派生活动时间戳永远陈旧 → 状态恒 `ready`。修复：`get_messages(sid, limit=5, latest=True)`（仍按时间升序返回最近 5 条） |
| 14.3 | ctx 口径（新问题 7） | §4.2 设计 `context.tokens` 由 Hermes 权威给出，实际 Hermes **无持久化当前窗口字段**（sessions.input_tokens 是累计；messages.token_count 全 NULL）。改用 Hermes 自己的 `estimate_request_tokens_rough(活跃消息)` + `get_model_context_length(model, provider=billing_provider)`（不传 provider，deepseek-flash 回退 128k；传 deepseek 才是 1M）。实机 19795/1000000 ≈ **2%**（旧累计/128k 显示 70% 是错的） |
| 14.4 | 待审批提醒（新问题 8） | 第一版闪 4 个 pill 边框；用户要求「闪烁是"待审批"文字本身闪烁」→ 改为 state pill 文字 `textColor` 每秒一次渐变脉冲（0.25s tick × α `[1.0, 0.55, 0.25, 0.55]`，1s 一个亮→暗→亮周期），边框保持常态 accent 色 |
| 14.5 | approval 数据源（新问题 5） | Hermes 审批是纯内存回调（无持久化）→ 用户插件 `desktop_attention` 在 `pre_approval_request` hook 写 `~/.hermes/approvals/approval_<sha256(session_key+command)[:10]>.json`（command/description/session_key/surface/created_at/timeout_seconds=300），`post_approval_response` 删除；wire `_read_pending_approval()` 读 JSON 按 created_at+timeout 判活并 sweep 过期文件。**插件改动需重启 Hermes 才加载** |
| 14.6 | S pill 标题（新问题 3） | wire session 增 `title` 字段（来自 `list_sessions_rich`）；主 bar 与 picker 优先显示会话标题（截断），fallback source → shortId |
| 14.7 | model 双路径（新问题 4） | wire 路径（pinned 优先）与 1.5s timer 兜底路径 displaySession 选择不一致 → 抽 `resolveDisplaySession(wire:)` 共用；`debugModelTrace`（HERMES_TB_DEBUG 门控）打印 session/title/model/ctx/state |
| 14.8 | pill 等宽（新问题 1） | 系统把 3 个自定义 item 拉伸到 ~170pt，session 按钮自适应 ~70pt；session 钳 `widthAnchor >= 149` + `frame.width` + autoresizingMask 三重 → 4 pill 等宽（149.5 vs 149.0） |
| 14.9 | picker（新问题 2） | `list_gateway_sessions(active_only=True)` 语义 = 仅 gateway session（TUI session_key 恒 NULL 永远进不来）；合并 `list_sessions_rich(sources=["tui","cli","desktop"])` 客户端过滤 `ended_at is None`，按 id 去重、last_active 降序 |
| 14.10 | 状态权威性 | §2 所述「Hermes 直接给 state」**未落地**：`hermes_source.py` 的 `state` 恒为 null（Tier A.3 预留），StateMachine 全部靠 §2 的时间窗 fallback 判定。Hermes 思考间隙（>12s 无消息落库）状态回 ready 是数据粒度限制；Tier A.3 仍是终极方案 |

**实机截图**：`screenshot/`（README §截图），含修复前（准备中/69% ctx）与修复后（工作中/3%、完成/4%、待审批/2%）对比。
