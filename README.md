# HermesTouchBar

**让 AI Agent 一直在你的视野里，但不要打断你。**

HermesTouchBar 把 Hermes Agent 的运行状态实时投影到 MacBook Touch Bar —— 不抢占系统控制条，任意前台 App 下都常驻可见。Agent 在后台干活，你干你的活，一瞥就知道它是在思考、在工作、还是等你审批。

[![macOS](https://img.shields.io/badge/macOS-13.0+-blue)](https://developer.apple.com/macos/)
[![Platform](https://img.shields.io/badge/Platform-MacBook%20Pro%20with%20Touch%20Bar-lightgrey)](#功能特性)

> 适配硬件：MacBookPro16,1（2019 16 寸 Intel MacBook Pro，带 Touch Bar）
> 依赖：Hermes Agent（`~/.hermes`）+ Python 3

---

## 它解决什么问题

AI agent 干活时，你常处于"它在后台跑、你忙自己的"状态。但你看不见它在干嘛：是卡住了、在等审批、还是马上要给你结果？HermesTouchBar 把这块信息放到你余光能瞄到的地方——不用切窗口，不打断手头的事。它不抢你的注意力，只在需要你出手（比如高风险操作审批）时才闪烁提醒。

---

## 功能特性

- **跨 App 常驻显示**：通过私有 `DFRFoundation` API 把状态条挂到系统 Touch Bar，任何前台 App 都能看到，无需窗口焦点
- **9 种状态实时映射**：空闲 / 准备中 / 思考中 / 工作中 / 输出中 / 待审批 / 完成 / 失败 / 网关断
- **真实上下文占用**：ctx 百分比来自 Hermes 自身的 token 估算与模型上下文窗口，显示当前会话的真实占用（而非累计用量）
- **待审批渐变闪烁**：出现高风险操作审批时，"待审批"文字每秒渐变闪烁，醒目但不打扰
- **会话标题 + 一键切换**：主栏显示当前会话标题，点击进入 picker 在多个会话间切换
- **皮肤热切换**：9 套内置皮肤 + 用户自定义 YAML，与 `hermes skin use` 1 秒内同步换色
- **5 个全局快捷键**：⌃⌥⌘H 打开 TUI / ⌃⌥⌘N 新会话 / ⌃⌥⌘A 通过审批 / ⌃⌥⌘X 取消 / ⌃⌥⌘S 下一皮肤
- **菜单栏常驻**：Dock 图标隐藏，系统控制条（亮度 / 音量 / Siri）始终保留

---

## 截图

主栏四个区块：状态 pill、实时上下文占用、当前模型、活跃会话。高风险操作审批时，"待审批"会渐变闪烁提醒。点击会话 pill 进入 picker，按标题与活跃时长在多个会话间切换。
<p align="center">
  <img src="screenshot/hermestouchbar-状态工作中.png" width="80%">
</p>

<p align="center">
  <img src="screenshot/hermestouchbar-状态完成.png" width="80%">
</p>

<p align="center">
  <img src="screenshot/hermestouchbar-状态待审批.png" width="80%">
</p>

<p align="center">
  <img src="screenshot/hermestouchbar-主界面.png" width="80%">
</p>




---

## 快速开始

```bash
cd HermesTouchBar
./scripts/build.sh
open build/HermesTouchBar.app
```

启动后：

1. 菜单栏右上角出现 ⚕ 图标，Touch Bar 控制条最右出现小 ⚕（tray badge）
2. 点击 ⚕ → 弹出主栏：`[状态] [ctx] [模型] [会话]`
3. 点击 `[会话]` → 进入 picker：`[< 返回] [会话列表...]`，选中即切换
4. 皮肤切换：菜单栏「选择皮肤 ►」子菜单，或 ⌃⌥⌘S 循环切换

---

## 工作原理

### 跨 App 常驻

macOS 公共 `NSTouchBar` API 只在前台 App 自己的窗口有焦点时渲染。本项目参考开源方案 [TouchBar-Pet](https://github.com/Heaaaaaaaa/TouchBar-Pet)，通过私有 `DFRFoundation`（dlopen + dlsym）实现：

1. `DFRElementSetControlStripPresenceForIdentifier` — 把小图标挂到系统控制条
2. `NSTouchBar presentSystemModalTouchBar:` — 把完整状态条挂到控制条之上
3. 系统控制条始终保留，互不冲突

### 数据通道

数据通过 in-process Python 内省直接读取 Hermes 运行时，不依赖文件轮询：

- `HermesPythonSource` 启动长跑 Python 子进程（`hermes_source.py`）
- 每 0.5s 输出一帧 JSON-lines（v1 schema）：gateway 状态、会话列表、最近消息、审批、皮肤、ctx
- Swift 端解码后经 `StateMachine` 判定状态，驱动 Touch Bar 刷新
- 子进程异常自动 1s 重启；找不到 Python 时回退 SQLite 只读读取

### 状态判定

状态机在本地做时间窗判定（如 5s 内工具调用 → "工作中"、12s 内正常结束 → "完成"），审批与网关状态来自 Hermes 数据流，优先级：`网关断 > 待审批 > 失败 > 工作中/思考/输出/完成 > 准备中 > 空闲`。

---

## 项目结构

```
HermesTouchBar/
├── HermesTouchBar/                  # App 壳（UI + 数据源）
│   ├── AppDelegate.swift            # 数据流编排 + 状态机驱动
│   ├── TouchBarController.swift     # Touch Bar 装配、drilldown、系统模态挂载
│   ├── Data/
│   │   ├── HermesPythonSource.swift # Python 子进程 + AsyncStream
│   │   └── hermes_source.py         # Hermes 运行时内省，输出 JSON-lines
│   ├── QuickActions/QuickActions.swift  # 5 个全局快捷键（Carbon）
│   ├── TouchBarPrivate/             # 私有 DFRFoundation 桥
│   └── Status/                      # SQLite 兜底读取 + 状态机
├── Domain/                          # 纯逻辑 SwiftPM 包（HermesDomain）
│   └── Sources/HermesDomain/        # 状态模型 / wire schema / 状态机 / 皮肤
├── screenshot/                      # 实机截图
├── scripts/                         # build.sh / test.sh
└── tests/                           # standalone smoke + XCTest
```

> 无 `.xcodeproj`：构建走 `scripts/build.sh`（swiftc 直接编译），`project.yml` 为 XcodeGen 备用模板。

---

## 测试

```bash
./scripts/test.sh
```

swiftc smoke 145 项断言 + Python 23 项 + XCTest 4 套件，覆盖皮肤解析、状态机边界、wire schema 解码、状态合并逻辑，全部独立编译运行、零外部依赖。

---

## 致谢

- [TouchBar-Pet](https://github.com/Heaaaaaaaa/TouchBar-Pet) — 私有 `DFRFoundation` 接入方案的早期参考

## 反馈与贡献

- 项目仍处快速迭代期，Bug / 体验问题 / 新想法：欢迎 [新建 Issue](../../issues/new)

## Roadmap

- Apple Silicon 支持
- Hermes 端权威状态直通（消除本地时间窗推断）
- 会话"近期活跃"过滤（清理长期占位的僵尸会话）

## License

本项目基于 [MIT License](./LICENSE) 开源。
