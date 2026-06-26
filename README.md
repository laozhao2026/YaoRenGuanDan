# 老赵摇人打掼蛋 Ver 1.0 beta

基于 [GuanDanInOffice](https://github.com/laozhao2026/GuanDanInOffice) 项目移植开发的 iOS 掼蛋 App。宿主手机既是服务器又是客户端，其他玩家通过浏览器加入游戏，人数不够 AI 自动补位。

---

## 快速开始

### 1. 生成 Xcode 项目

```bash
cd GuanDanApp
xcodegen generate
```

### 2. 用 Xcode 打开

双击 `GuanDanApp.xcodeproj`，在 Signing & Capabilities 选你的 Apple ID Team。

### 3. 运行

- **模拟器**：顶部 Run Destination 选任一 iPhone 模拟器，`Cmd + R`
- **真机**：USB 连接 iPhone，选你的手机，`Cmd + R`。首次需在 iPhone 设置里开启开发者模式

---

## 怎么玩

1. 宿主打开 App → 内嵌服务器自动启动
2. 顶部栏显示共享地址，如 `192.168.1.5:8080`
3. 其他人在手机浏览器输入这个地址 → 加入房间
4. 人数不够 4 人，AI Bot 自动补齐
5. 房主（座位 0）点"开始游戏"

---

## 技术架构

```
宿主 iPhone（Server + Client）
┌──────────────────────────────────────┐
│  SwiftUI App                         │
│  ┌────────────────────────────────┐   │
│  │  WKWebView → Web 客户端        │   │  ← 宿主自己的游戏界面
│  └────────────────────────────────┘   │
│  ┌────────────────────────────────┐   │
│  │  GameServer（NWListener）       │   │
│  │  ├── HTTP + SSE 服务器          │   │  ← 端口 8080
│  │  ├── RoomManager 房间管理       │   │
│  │  ├── MatchManager 对局管理      │   │
│  │  └── GameManager 单局管理       │   │
│  └────────────────────────────────┘   │
│  ┌────────────────────────────────┐   │
│  │  GameCore（纯 Swift 逻辑）      │   │
│  │  ├── Types 类型定义             │   │
│  │  ├── Deck  牌组与洗牌           │   │
│  │  ├── Rules 牌型识别与比较       │   │
│  │  └── Bot   AI 出牌决策          │   │
│  └────────────────────────────────┘   │
└──────────────────────────────────────┘
         │  HTTP + SSE
         ▼
  远程玩家 1（浏览器）     远程玩家 2-3 或 AI Bot
```

### 通信协议

| 接口 | 方法 | 说明 |
|------|------|------|
| `/` | GET | Web 客户端页面 |
| `/api/join` | POST | 加入房间 |
| `/api/start` | POST | 房主开始游戏 |
| `/api/action` | POST | 游戏操作（出牌/过牌/进贡/技能等） |
| `/api/events` | GET | SSE 实时状态推送 |
| `/api/ping` | GET | 健康检查 |

### SSE 事件

| 事件 | 方向 | 说明 |
|------|------|------|
| `roomState` | 服务端→客户端 | 房间状态（玩家列表、准备状态） |
| `gameState` | 服务端→客户端 | 游戏状态（手牌、当前回合、出牌记录） |
| `matchStarted` | 服务端→客户端 | 对局开始 |
| `gameOver` | 服务端→客户端 | 单局结束 |
| `matchOver` | 服务端→客户端 | 对局结束 |
| `chatMessage` | 双向 | 聊天消息 |
| `error` | 服务端→客户端 | 错误提示 |

---

## 游戏规则

### 牌型（10 种，均支持万能牌补位）

| 牌型 | 张数 | 说明 |
|------|------|------|
| 单张 | 1 | |
| 对子 | 2 | 同点数 |
| 三张 | 3 | 同点数 |
| 三带二 | 5 | 三同点 + 一对 |
| 顺子 | 5 | 连续点数 |
| 钢板（Tube） | 6 | 三连对 |
| 木板（Plate） | 6 | 连二同三 |
| 炸弹 | 4+ | 同点数 |
| 同花顺 | 5 | 同花连续 |
| 四大天王 | 4 | 2 小王 + 2 大王 |

### 炸弹层级

```
四大天王 > 6+张炸弹 > 同花顺 > 5张炸弹 > 4张炸弹
```

### 红心级牌万能牌

当前等级的红心牌（如打 2 时的 ♥2）可作为万能牌代替任意牌，搭配所有牌型。

### 进贡/还贡

| 上局结果 | 进贡 | 下局先手 |
|---------|------|---------|
| 双扣（1, 2 同队） | 末→头，三→二 | 进贡最大者 |
| 单扣（1, 3 同队） | 末→头 | 末游先手 |
| 保级（1, 4 同队） | 不进贡 | 头游先手 |

- 输方有 2 张大王 → **抗贡**，免进贡
- 进贡必须出最大牌，还贡任意

### 升级/对局

- 从 2 打到 A（A = 14 级）
- 双扣升 3 级，单扣升 2 级，保级升 1 级
- A 级连赢 2 局才最终获胜

---

## 项目结构

```
GuanDanApp/
├── project.yml              # xcodegen 项目配置
├── Package.swift            # Swift Package Manager 清单
├── Sources/
│   ├── GameCore/            # 核心游戏逻辑（纯 Swift，无 UI 依赖）
│   │   ├── Types.swift      # 牌、牌型、技能卡、历史记录等类型
│   │   ├── Deck.swift       # 108 张双副牌创建与洗牌
│   │   ├── Rules.swift      # 10 种牌型识别、万能牌补位、牌型比较
│   │   └── Bot.swift        # AI 出牌决策（自由出、跟牌、炸弹、记牌）
│   ├── GameServer/          # 内嵌游戏服务器
│   │   ├── HTTPServer.swift # NWListener TCP 服务器 + HTTP 解析 + SSE
│   │   ├── WebAssets.swift  # 内嵌 Web 客户端文件（HTML/CSS/JS）
│   │   ├── RoomManager.swift# 房间管理（加入/离开/座位/准备/聊天）
│   │   ├── MatchManager.swift# 对局管理（2→A 系列赛）
│   │   └── GameManager.swift# 单局管理（进贡/出牌/回合/Bot 调度）
│   └── GuanDanApp/          # iOS App 入口
│       ├── App.swift        # SwiftUI @main
│       ├── ContentView.swift# WKWebView + 服务器状态栏 + 分享
│       └── ServerViewModel.swift # 服务器生命周期管理
├── Resources/
│   ├── Assets.xcassets/
│   │   └── AppIcon.appiconset/  # App 图标（深红底金色边扑克风格）
│   └── WebClient/           # Web 客户端源文件（编译时内嵌到 WebAssets.swift）
│       ├── index.html
│       ├── css/style.css
│       └── js/game.js
└── README.md
```

---

## AI Bot 设计

### 决策流程

```
decideMove(target)
├── target == nil（自由出牌）
│   ├── 优先出长牌型：钢板 > 木板 > 三带二 > 顺子
│   ├── 最后出对子或中等单张
│   └── 不留炸
├── findBeat（跟牌）
│   ├── 单张/对子/三张/三带二：找最小的能压过的
│   ├── 顺子/钢板/木板：生成所有可能组合，挑最小的能压过的
│   ├── 万能牌配合：1 万能 + 1 普通牌凑对子
│   └── 炸弹不在这里处理
└── findBomb（炸牌）
    ├── shouldBomb：判断是否值得炸
    │   ├── 自身剩 ≤ 3 张 → 必炸
    │   ├── 对手快出完 → 必炸拦截
    │   ├── 手牌 > 15 张 + 对方出单张/对子 → 不炸
    │   └── 队友已赢 → 保守
    ├── 四大天王 > 同花顺 > 6+ 炸弹 > 5 炸弹 > 4 炸弹
    └── 能炸则炸最小的，炸不了 pass
```

### 游戏上下文（BotGameContext）

Bot 接收当前游戏状态上下文，用于辅助决策：
- `opponentCardCounts`：对手剩余牌数
- `teammateWon`：队友是否已出完
- `winners`：当前已出完的玩家列表
- `mySeat`：自己的座位号
- `visibleHighCards`：已出现的大牌数量

---

## 开发记录

### 移植阶段

| 层次 | 内容 | 状态 |
|------|------|------|
| GameCore | Types / Deck / Rules / Bot 完整移植 | ✅ |
| GameServer | HTTP+SSE 服务器（Network.framework） | ✅ |
| GameServer | Room / Match / Game 管理器 | ✅ |
| iOS App | SwiftUI + WKWebView 宿主界面 | ✅ |
| Web 客户端 | HTML + CSS + JS 单页应用 | ✅ |

### 规则增强

| 改动 | 说明 |
|------|------|
| 万能牌补位 | 所有 10 种牌型全部支持万能牌补位（原项目仅 6 种） |
| 大小王对子 | 俩大王 / 俩小王可当对子出 |
| 双扣自动结束 | 头二名同队直接结束，输方不再继续打 |
| 级牌计数修复 | 级牌（值 19）不被排除在牌型检测外 |

### Bot 优化

| 改动 | 说明 |
|------|------|
| 顺子跟牌 | Bot 能识别并跟顺子（原项目不会） |
| 钢板/木板 | Bot 能识别并跟钢板/木板（原项目不会） |
| 炸弹克制 | 加 shouldBomb 决策，不盲目炸 |
| 队友配合 | 队友赢了 Bot 更激进追求双扣 |
| 记牌 | 基础高牌计数辅助决策 |
| 防冻死 | Bot 出牌失败自动 pass，不卡死游戏 |

### 界面迭代

| 改动 | 说明 |
|------|------|
| 强制横屏 | 牌区宽度翻倍 |
| 手牌紧凑布局 | 卡片 24×38px，flex-wrap 自动换行，max-height 限制不滚屏 |
| 出牌按钮反馈 | 按钮文字变化替代 alert（WKWebView 不弹 alert） |
| 去掉准备机制 | 只有房主能开始游戏 |
| 去掉对局记录浮动框 | 释放界面空间 |
| App 图标 | 深红底金色边框扑克牌风格，17 种尺寸 |
| 称号 | App 桌面名"摇人掼蛋"，游戏内标题"老赵摇人打掼蛋 Ver 1.0 beta" |

### 关键 Bug 修复

| Bug | 根因 | 修复 |
|-----|------|------|
| 加入游戏无响应 | `API.act` 函数未定义 | 补全 `act` 方法 |
| 出牌按钮点不动 | WKWebView 不触发 addEventListener | 改用 inline `onclick` |
| 服务器端口显示为 0 | NWListener 异步返回端口，代码同步读取 | 用 stateUpdateHandler + onReady 回调 |
| Web 页面 404 | Bundle 路径查找失败 | Web 文件内嵌到 Swift 代码（WebAssets.swift） |
| HTTP POST body 丢失 | `components(separatedBy: "\r\n\r\n")` 分割全匹配 | 改用 `range(of:)` 只找第一个边界 |
| TCP 分包丢数据 | receiveHTTP 只收一次就解析 | 增加 pendingBuffer 累积接收 |
| receive 并发冲突 | 回调内同步调下一次 receive | `DispatchQueue.main.async` 延迟调用 |
| SSE 广播链断裂 | Room.onBroadcast nil | fallback 到 RoomManager.shared |
| 炸弹后服务端崩溃 | `try!` JSON 编码失败 | 全部改为 `try?` |
| Bot 出牌卡死 | 无效牌型后不推进回合 | 防冻死机制：失败后自动 pass |
| 级牌组不了炸弹 | `v <= 14` 排除了值 19 的级牌 | 改为 `<= 19`，大小王也放开 |
| 接风逻辑缺失 | advanceTurn 无接风判断 | 出完牌由队友接风先出 |

---

## 技术选型

| 层 | 技术 | 原因 |
|----|------|------|
| iOS UI | SwiftUI | Apple 官方推荐，声明式 UI |
| WebView | WKWebView | 宿主同享 Web 客户端体验，免开发两套 UI |
| HTTP 服务器 | Network.framework (NWListener) | iOS 原生，零外部依赖 |
| 实时通信 | Server-Sent Events (SSE) | 比 WebSocket 简单，浏览器原生支持 |
| 项目生成 | xcodegen | YAML 配置生成 .xcodeproj，可复现 |
| 图标生成 | Python PIL | 17 种尺寸自动缩放，深红扑克风格 |
| 游戏逻辑 | Swift | 与 iOS 生态一致，编译时类型安全 |

---

## 许可证

基于 GuanDanInOffice 项目（MIT License），本项目同样采用 MIT License。

---

*老赵摇人打掼蛋  🃏  Ver 1.0 beta — 2026.06*
