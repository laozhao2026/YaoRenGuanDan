# 掼蛋（GuanDan）游戏开发日志

## 项目概述

**掼蛋**是一款用 Swift 编写的多人掼蛋纸牌游戏。iOS/macOS 宿主设备作为 HTTP 服务器，其他玩家通过浏览器加入对局，无需安装客户端。

### 架构

```
GuanDanApp
├── GameCore/        # 游戏核心引擎（牌型定义、出牌规则、Bot、AI）
├── GameServer/      # 网络服务层（HTTP Server + SSE 实时推送 + Room/Match 管理）
├── WebClient/       # Web 前端（HTML + CSS + JS，通过浏览器加入对局）
└── GuanDanApp/      # iOS/macOS App 入口与 UI
```

### 规模

- **Swift 源文件**: 13 个，共 3461 行
- **Web 前端**: 3 个文件（index.html / style.css / game.js），共 629 行
- **总计**: 16 个源文件，4090 行

---

## 开发阶段与关键修复

### 阶段一：项目审查与编译修复

**目标**: 让项目从零编译通过。

- 审查 GitHub 仓库结构，确认 4 个模块分层：GameCore → GameServer → GuanDanApp + WebClient
- 原始项目存在跨模块 import 导致的编译错误（目标模块间循环依赖）
- 修复方案：回退为单 target 编译模式，将所有 Swift 源文件纳入同一 target，去除跨模块 import 声明
- 添加必要的 `@available(iOS 17.0, macOS 14.0, *)` 平台可用性声明

### 阶段二：运行时 Bug 修复

#### Bug 1: onBroadcast 双重赋值导致 gameOver 拦截失效

**现象**: 一局结束后不触发升级/进贡流程，游戏卡住。

**根因**: `MatchManager.startNextGame()` 中对 `game.onBroadcast` 赋值了两次——第一次是正确的（包含 gameOver 处理逻辑），第二次是空壳闭包，覆盖了第一次赋值。

**修复**: 删除第二次重复的 `game.onBroadcast = { ... }` 赋值。

**涉及文件**: `Sources/GameServer/MatchManager.swift`

---

#### Bug 2: 添加 GameLogger 调试日志模块

**目标**: 运行时黑盒问题难以定位，需要全路径日志。

**实现**:
- 新建 `Sources/GameCore/GameLogger.swift`，环形缓冲区记录最近 500 条带毫秒时间戳的事件
- 注入到 `GameManager` 所有关键路径：发牌、出牌、过牌、回合切换、游戏结束等
- `GameState` 新增 `logEntries` 字段，前端可通过 SSE 订阅日志流

---

#### Bug 3: Swift 6 严格并发适配

**现象**: Swift 6 编译器对跨 actor 边界的类型传递报错。

**修复**:
- `GameLogger` 添加 `@unchecked Sendable` 声明
- `GameState.Entry` 添加 `Sendable` 协议遵循

---

#### Bug 4: Free turn bot 死锁

**现象**: Bot 在 free turn（自己刚出的牌无人能管）时尝试 pass，被规则拒绝后 `handlePass` 的 `guard` 拦截直接 return，不触发 `advanceTurn`，导致回合卡死。

**修复**: 新增 `botForcePassOrPlay()` 函数。Bot 尝试 pass 时检测是否处于 free turn：若是则强制打出手中最小的单张牌，保证回合能推进。

**涉及文件**: `Sources/GameCore/Bot.swift`

---

#### Bug 5: SSE 断连导致前端冻结

**现象**: 进入游戏后，若 SSE 连接断开，前端不再重连，界面永久卡住。

**根因**: `WebAssets.swift` 中 `sseSource.onerror` 回调仅在 `!state.inGame`（不在游戏中）时触发重连。一旦进入游戏，断连后重连逻辑被跳过。

**修复**: SSE 状态为 `EventSource.CLOSED` 时无条件 2 秒后重连，不受 `inGame` 状态限制。

**涉及文件**: `Sources/GameServer/WebAssets.swift`

---

#### Bug 6: 游戏结束不进入升级/进贡/下一局（本次会话核心问题）

这是本次开发会话中修复的最复杂问题，涉及 3 个子问题联动。

**子问题 6.1: endGame 时赢家数量不足**

`endGame` 触发时机是第 3 名玩家出完牌（因为第 4 名无需再出），此时 `winners` 数组只有 3 人。`handleGameEnd` 的 `guard winners.count == 4` 直接拦截，不执行任何结算逻辑。

**修复**: 在 `endGame` 前自动补全第 4 名（最后一名未出完牌的玩家）。

---

**子问题 6.2: 升级信息未广播给前端**

旧流程中 `handleGameEnd` 只调用 `onGameOver` 回调，前端仅弹出一个 toast 提示，看不到排名、升级信息、双方等级变化。

**修复**:
- 新增 `gameResult` SSE 事件类型
- 前端新增 `resultsOverlay` 面板，展示：
  - 4 名玩家的最终排名
  - 双方升级信息（升几级）
  - 双方当前等级
  - 5 秒倒计时后自动进入下一局

**涉及文件**: `Sources/GameServer/GameManager.swift`, `Resources/WebClient/js/game.js`, `Resources/WebClient/css/style.css`, `Resources/WebClient/index.html`

---

**子问题 6.3: teamLevels 字典序列化崩溃**

`gameResult` 广播中 `teamLevels` 类型为 `[Int: Int]`，`JSONSerialization` 不支持非字符串 key 的字典，传入后服务器进程崩溃。

**修复**: 序列化前将 `[Int: Int]` 转换为 `[String: Int]`，key 统一转为字符串。

---

### 阶段三：UI 优化

#### App 图标

- 设计深红底色 + 金色边框 + ♠♥ 排列的掼蛋主题 AppIcon
- 生成全部所需尺寸（20/29/40/60/76/83.5/1024 pt，含 @2x @3x）

#### 牌面视觉增强

- 牌面尺寸从 24×38px 增大到 34×52px（提升可读性）
- 花色颜色优化：
  - ♠ 黑桃：`#0d0d0d`（深黑，避免灰色感）
  - ♣ 梅花：`#1b5e20`（墨绿，与黑桃区分明显）

**涉及文件**: `Sources/GameServer/WebAssets.swift`

---

## 技术栈

| 层级 | 技术 |
|------|------|
| 语言 | Swift 5 |
| 平台 | iOS 17+ / macOS 14+ |
| 网络 | Network.framework（NWConnection 自建 HTTP 服务器） |
| 实时推送 | EventSource / SSE（Server-Sent Events） |
| 工程管理 | xcodegen + Package.swift |
| Web 前端 | 原生 HTML5 + CSS3 + JavaScript（无框架依赖） |
| 版本控制 | Git + GitHub |

---

## 文件清单

### GameCore（游戏引擎）

| 文件 | 行数 | 职责 |
|------|------|------|
| `Sources/GameCore/Types.swift` | 161 | 核心类型定义：Card、Suit、Rank、PlayType、HandCombination、GameState |
| `Sources/GameCore/Deck.swift` | 45 | 两副牌（108张）生成与洗牌 |
| `Sources/GameCore/Rules.swift` | 295 | 出牌规则校验、牌型识别、大小比较、特殊牌型（炸弹/火箭/同花顺等） |
| `Sources/GameCore/Bot.swift` | 467 | AI Bot 决策引擎：拆牌策略、跟牌/过牌判断、free turn 处理 |
| `Sources/GameCore/GameLogger.swift` | 60 | 调试日志模块：环形缓冲区、毫秒时间戳、SSE 推送 |

### GameServer（网络服务）

| 文件 | 行数 | 职责 |
|------|------|------|
| `Sources/GameServer/HTTPServer.swift` | 424 | 基于 NWConnection 的 HTTP 服务器：路由分发、静态资源、CORS |
| `Sources/GameServer/RoomManager.swift` | 253 | 房间管理：创建/加入/离开/列表 |
| `Sources/GameServer/MatchManager.swift` | 148 | 对局管理：初始化、回合控制、升级/进贡流转 |
| `Sources/GameServer/GameManager.swift` | 673 | 游戏核心逻辑：发牌、出牌处理、gameResult 结算、SSE 广播 |
| `Sources/GameServer/WebAssets.swift` | 713 | Web 前端资源内嵌：HTML/JS/CSS 模板渲染、牌面 SVG 生成、SSE 客户端 |

### GuanDanApp（App 入口与 UI）

| 文件 | 行数 | 职责 |
|------|------|------|
| `Sources/GuanDanApp/App.swift` | 13 | App 入口 |
| `Sources/GuanDanApp/ContentView.swift` | 105 | 主界面：服务器开关、房间管理、对局显示 |
| `Sources/GuanDanApp/ServerViewModel.swift` | 104 | 视图模型：服务器状态绑定、UI 数据流 |

### WebClient（Web 前端）

| 文件 | 行数 | 职责 |
|------|------|------|
| `Resources/WebClient/index.html` | 90 | 前端页面结构 |
| `Resources/WebClient/css/style.css` | 95 | 样式表：牌面布局、resultsOverlay、响应式设计 |
| `Resources/WebClient/js/game.js` | 444 | 游戏客户端：SSE 事件处理、出牌交互、结算面板 |

---

## Git 提交历史

```
711e136 老赵摇人打掼蛋 Ver 1.0 beta
```

---

*文档生成时间: 2026-06-27*
