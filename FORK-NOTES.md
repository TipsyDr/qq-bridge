# FORK NOTES —— 让 Derpyu520/qq-bridge 在 macOS 上跑起来

> 本文件记录 fork 的改造点与已验证结论。上游：`Derpyu520/qq-bridge` @ `a49877f`（v0.2.1-r1）。
> 目标：**保留上游全部功能**，只换掉「Windows-only 的 QQ 协议端」这一层。

## 结论（已实测）

**不需要重写传输层，也不需要改 `src/bridge.js`。** 上游唯一硬耦合是 `@snowluma/sdk`，
而这个 SDK 实现的是**标准 OneBot v11 协议**，可以对接任意 OneBot v11 服务端（含 NapCat）。

已验证证据：

| 验证项 | 结果 |
|---|---|
| `@snowluma/sdk` 对接**非 SnowLuma** 的 OneBot v11 服务端 | ✅ WS 连接、`get_login_info`、通用 `request('send_group_msg')`、高层 `sendGroupMessage(id, text())`、`onGroupMessage` 事件全部正常（自建 mock 服务端实测） |
| 依赖安装 + `postinstall` 补丁 | ✅ `added 128 packages`，SDK 的 ESM 扩展名 bug 被自动修补（13 个文件） |
| 静态审计 `npm run test:audit` | ✅ 28/35 脚本通过（其余需要运行中的 DSH 或 QQ） |
| DSH 桌面版 **0.2.1-rc.3** 上：`settings.describe` / `session/create` / `session/selectModel` / `events/mux` + `session/follow` / `session/prompt` → `turn/end` | ✅ **全部通过**，收到回复「收到」 |
| `session/selectModel` 指定 `comate / DeepSeek-V4.1-Flash` | ✅ 生效（`reasoningEffort: off`） |

⚠️ 一个实测发现：自测默认模型（desktop 的 `Claude Sonnet 5.5`）对自测会话返回
`Provider finish_reason: content_filter`（`PI_AI_ERROR`），**换 `DeepSeek-V4.1-Flash` 即正常**。
桥的场景里建议在 `config.json` 显式钉住 `dsh.model`，别用桌面版默认的 Claude。

## 改造清单（4 项，都不碰核心逻辑）

### 1. QQ 侧换成 NapCat（macOS 用 Docker）

macOS **没有** SnowLuma 构建（截至 v2.2.1，官方只发 Windows x64 / Linux x64 / Linux arm64）。

> 2026-10-30 更正：fork 时（v1.x 时代）上游只有 `native/snowluma-win32-x64.{dll,node}`，
> 所以当时记的是「只好 Windows」。现在上游已提供 **Linux arm64** 发行包，理论上是能在
> Apple Silicon 的 Docker 里跑的 —— 难点不在平台，而在雪上加霜的两件事：
> ① SnowLuma 不提供 Docker 镜像，得自己把 Linux QQ 装进容器并配 hook；
> ② 桥接钉的 `@snowluma/sdk` 是 1.14.20，而 npm 上已是 **2.2.1**，跨大版本要改代码 + 回归。
> 结论（继续用 NapCat）不变，但原因从「跑不了」改成「能跑但不划算」。
改用 NapCat 官方 Docker 镜像 `mlikiowa/napcat-docker`（134.9 万次拉取，2026-10-26 更新）：

```bash
docker run -d --name napcat -p 3000:3000 -p 3001:3001 -p 6099:6099 \
  -v ~/napcat/config:/app/napcat/config \
  -e NAPCAT_GID=0 -e NAPCAT_UID=0 mlikiowa/napcat-docker:latest
# WebUI http://127.0.0.1:6099 扫码登录小号 → 开 HTTP(3000) / WS(3001)
```

`config.json` 指向它（NapCat 的 token 自己定，两个 token 可以一致）：

```json
"snowluma": {
  "wsUrl": "ws://127.0.0.1:3001",
  "httpUrl": "http://127.0.0.1:3000",
  "accessToken": "<NapCat 里配的 token>",
  "followDiscoveredEndpoint": false
}
```

`followDiscoveredEndpoint: false` 必须关：否则端点自愈会去读 SnowLuma 的
`config/onebot_<uin>.json`，读不到就想把 `wsUrl` 改回去。

### 2. 降级 SnowLuma 专有扩展（都有 try/catch，失效不影响主链路）

| 能力 | 用到的 action/事件 | NapCat 上 |
|---|---|---|
| 收藏表情同步 | `fetch_custom_face_detail` / `add_custom_face` / `modify_custom_face` | 大概率没有 → 表情库空，表情包发送降级 |
| 戳一戳 | `send_poke` / `group_poke` | ✅ 标准 OneBot，支持 |
| 账号上下线 | `bot_status` 事件 | 不发 → 已有 `try/catch` 降级 |
| 接收链路健康 | 心跳 `status.good` | NapCat 心跳有 `status.online/good`，大概率可用；没有则静默降级 |
| 唤醒配置 / 连发 | `set_wake_config` / `send_burst` | 专有 → 不影响主链路 |

**待办**：跑一轮把日志里所有「连续失败」的专有 action 收集起来，逐个加"能力探测"（跑一次成功就记住，
失败就永久跳过并打一条日志），避免每轮都重试刷屏。

### 3. macOS 平台脚本

- `start.bat` / `restart.bat` → 补 `start.sh`（`node src/bridge.js`，守护用 launchd 或 `while` 循环）
- `scripts/harden-state-acl.mjs` 用 `icacls`：脚本自身设计为"失败不阻塞"，macOS 上应改成
  对 `state/`、`config.json` 做 `chmod 600/700`（含 secrets）
- `scripts/*.ps1`（若有）不参与运行，忽略

### 4. DSH 侧端口问题（必须解决）

上游默认 `dsh.baseUrl = http://127.0.0.1:3080`（`dsh web` 的固定端口）。
本机跑的是**桌面版**，其 Host API 端口每次启动都变（本次 `57923`，上次 `58440`/`56446`）。

两条路，二选一：

- **A（推荐）**：跑一个固定端口的 `dsh web`，桥连 3080。桌面版与 `dsh web` 可共存（不同 profile）。
- **B**：给桥加"端口自动发现"——扫 `127.0.0.1` 上的候选端口，用 `settings.describe` 探活。
  注意桌面版对 `/` 返回 401，探活要用带鉴权的 RPC 而不是简单 GET。

## 已完成的本地改动

| 文件 | 状态 | 说明 |
|---|---|---|
| `scripts/detect-dsh-port.mjs` | ✅ 新增，已实测 | 用 lsof + `settings.describe`（带鉴权 RPC）找桌面版 Host API 端口，`--write` 写回 `config.json`。实测命中 `127.0.0.1:57923`（`namespace 23 个, writable=true`） |
| `start.sh` | ✅ 新增，语法校验通过 | 对应 `start.bat`：收紧 `config.json`/`state` 权限 → 跑 ACL 脚本 → 自动发现 DSH 端口 → 守护循环（崩溃 5 秒重启，`code 2` 表示已有实例）。`--once` 退出即结束 |
| `config.json` | ✅ 已生成（600 权限，已被 `.gitignore` 忽略） | `snowluma` 指向 NapCat、`followDiscoveredEndpoint: false`、`dsh.model = DeepSeek-V4.1-Flash`、`dsh.reasoningEffort = low`、`sessionCwd` 指向工作区 |
| `src/state-acl.mjs` | ✅ **无需改动** | 上游已实现非 Windows 分支：`hardenDir → chmod 700`、`hardenFile → chmod 600`、`manualDirCommand → chmod -R go-rwx` |
| `src/bridge.js` | ✅ **零改动** | 传输层不需要替换（见上方 PoC） |

### 待用户填的两处

`config.json` 里这两项是空的，安全默认会**拒绝所有人**：

```json
"allow": { "private": [], "groups": [] },   // 填自己的 QQ 号 / 要用机器人的群号
"ownerQQ": null,                             // closed-agent 模式（QQ 上操控 DSH）需要填
```

## 下一步（需要人配合的部分）

1. 起 Docker + NapCat 容器，扫码登录**小号**（不要主力号）
2. NapCat WebUI 里开 HTTP 3000 / WS 3001，记下 token
3. 复制 `config.example.json` → `config.json`，按上面第 1、4 条改
4. `node src/bridge.js`，控制台看 `http://127.0.0.1:3100`
5. 私聊/群里测试，重点验：文本往返、引用回复、图片、审批通道、`/model`

## 已知风险

- NapCat 属第三方协议端，账号风控风险由使用者承担（上游 README 的「合规提醒」同样适用）
- 上游适配的是 DSH `0.2.1-rc.2`，本机是 `rc.3`：本次已验证的 RPC 全部可用，但上游自带的
  `scripts/verify-dsh-021-adaptation.mjs` 还应在 rc.3 上完整跑一遍
- 桌面版重启后端口变化会让桥失联（见第 4 条）

## 联调实测结果（macOS + NapCat Docker）

| 环节 | 结果 |
|---|---|
| NapCat 镜像 | `mlikiowa/napcat-docker:latest`，**linux/arm64 原生**（非 Rosetta），2.07 GB |
| 容器 | `-p 127.0.0.1:3000/3001/6099`，`NapCat.Core 4.18.41`，挂载 `~/qq-bridge-napcat/{config,qqdata}` |
| QQ 登录 | ✅ 小号 `1162470069 / 大肥鱼`，`get_status → online:true, good:true` |
| OneBot 网络 | ✅ 手写 `onebot11_<uin>.json`（HTTP 3000 + WS 3001，`messagePostFormat: array`，token 鉴权）—— NapCat 首次登录生成的配置里 `network` 全是空数组，必须自己填 |
| SDK → NapCat | ✅ `getLoginInfo` / `getStatus` / `getGroupList` 全通，`on('open')` 正常 |
| 桥 → NapCat | ✅ 日志 `SnowLuma 已连接：ws://127.0.0.1:3001`、`机器人昵称: 大肥鱼`（**bridge.js 零改动**） |
| 桥 → DSH | ✅ `DSH 已就绪（模式: reserved2）`、`/api/status` → `dshReady: true` |
| 控制台 | ✅ `http://127.0.0.1:3100`，token 自动生成存于 `state/console-token` |

### 实测的降级行为（与预判一致，均不影响主链路）

- **心跳缺 `status.good`**：NapCat 的 heartbeat 没这个字段 → 桥自动改用 `get_status` 兜底，
  `/api/status` 显示 `goodSource: "get_status"`、`good: true`、`degraded: false`。健康检测**照常工作**。
- **收藏表情同步 0 个**：`fetch_custom_face_detail` 是 SnowLuma 扩展 → 日志
  `[sticker] 已同步 QQ 收藏表情 0 个（via ws）`，没有重试刷屏、没有报错。
- **`onebot11_<uin>.json` vs 上游期望的 `onebot_<uin>.json`**：文件名不同，所以
  `followDiscoveredEndpoint` 必须设 `false`（已设），否则端点自愈会摸空。

### 端口绑定（安全）

首次用 `-p 3000:3000` 会绑到 `0.0.0.0`，同网段任何人都能调这台机器人（发消息/拉群成员）。
必须写 `-p 127.0.0.1:3000:3000`。代价是重建容器后 QQ 不认之前的登录态（快速登录列表为空），要重扫一次。

### 还差的一步

`setup-dsh.mjs desktop` 已写入 3 个 MCP server + 2 个 preset bundle，并跑通
`dsh plugin --profile desktop install`。但**MCP 要重启 DSH 才加载**：在此之前
`reserved2`（AI 自主收发）没有工具可用，先用 `chat` 模式（被动回复）验证往返。

## 本地新增：闲置会话回收（上游没有）

**问题**：QQ 侧冷场后，桥不会主动退役会话，DSH 侧上下文只增不减，涨到窗口上限就触发 compaction。
实测 compaction 一次要重算 30~50 万 tokens（`totals.cacheMiss` 26 万就是这么来的），是账单主要来源；
而稳态下每轮 cacheHit 高达 93~99%，几乎不花钱。所以省钱的杠杆在「别让会话长到要压缩」，不在「砍 prompt」。

**实现**：`src/bridge.js` 里新增 `recycleIdleSessions()`，挂独立 `setInterval(…, 60_000)`，
复用上游已有的 `retireSession(key)`（会 stopSessionWork + archiveSession）。
配置项 `socialV2.sessionRecycleIdleMs`（**默认 0 = 关闭**，行为与上游一致；本机设 600000 = 10 分钟）。

踩过的坑：第一版挂在 `socialLoopTick()` 里，但那个循环被 `isSocialEnabled()` 挡着——
它只认 `currentMode === 'reserved'`（一代仿真），`reserved2` 下第一行就 return，回收永远不跑。
所以必须用独立定时器，不能复用社交状态机。

**实测**：阈值临时调到 30 秒 → 60 秒内日志出现
`[recycle] private:[OWNER_QQ] 闲置 16 分钟 → 退役会话`，`state/sessions.json` 映射清空。

**代价**：冷场超阈值后再说话，AI 会是新会话（上下文从零），靠 Hindsight 的 `qq-workspace` bank 接住记忆。

## 本地新增：唤醒概率与注入瘦身

- `socialV2.wake.recommendedProbability` 0.05 → **0.15**；同时改了 `state/social-v2.json` 里两个 peer 的
  `triggers.probability`（只改前者不生效，那只是“推荐值”）
- 桥注入精简：删【引用】整段；【时间感】规则移入 preset（桥只留“现在几点/最新一条多久前”）；
  【首回复节奏】150→55 字、【沉睡前强制等待】300→45 字（preset 里有完整版）
- preset 新增【时间感】三档规则（10 分钟 / 10~120 分钟 / 120 分钟以上）

## 纠正：两个曾经写错的结论（2026-10-28 复核）

**① “上下文涨到 128k 就触发 compaction” —— 错。**
窗口实测是 `1048576`（`comate/DeepSeek-V4.1-Flash` 的 `contextWindow`，以及 `dsh-llm-deepseek` 的
`OFFICIAL_CONTEXT_WINDOW` 都是 1M），`dsh-compaction-basic` 的 `DEFAULT_THRESHOLD_RATIO = 0.8`，
所以触发点是 **838k**。128k 那个数字来自 2026-10-27 排查“回复被截断”时的旧配置 `131072`，
已被后续改成 1M，引用前必须重新查 `cordis.patch.yml`。

**② “compaction 一次重算 30~50 万 tokens，是账单主要来源” —— 错。**
`state/token-usage.jsonl` 里的 `k:"base"` 是**会话累计基线快照**（`token-ledger.js` 的
`baselines.get(sid)`，`compact()` 时重写），不是单次请求。那条 `in=488469` 是 session ce0899 的
整场累计。实际**一次 compaction 都没发生过**（最大会话 41.8k）。

因此「闲置会话回收」的定位应修正为：**防止长期运行缓慢爬到 838k 的保险**，不是省钱杠杆。
`socialV2.sessionRecycleIdleMs` 设 0 即可关闭（关闭后与上游行为一致）。

**读成本数据的正确姿势**：真实单轮成本看 `k:"turn"` 记录里 `b.cacheMiss`（每步几百到 1900），
以及 `cacheHitRate`（实测 84.9%~99%）；`totals.cacheMiss` 里还有各会话首轮全量（每次约 2~2.3 万）。

## 本地新增：qq_wake_peer（AI 主动找别人说话）

**问题**：会话级令牌隔离意味着 AI 在 A 的会话里**不能**给 B 发消息（`agentTokenOk(key, token)` 只认本会话）。
用户明确要求"让它去陪某人聊天"时，AI 只能说"我发不出去"。

**解法**：不做跨会话直发（那会破坏隔离），而是让 AI **请求桥去唤醒目标会话** ——
目标会话里的"另一个自己"用自己的令牌开口。桥侧加了限制：

- `/api/socialV2/wake` 从 `adminOnlyV2Paths` 移出，允许 agent token 调用
- token 必须命中 `KNOWN_AGENT_TOKENS`
- 目标必须通过 `modeAllowed`（白名单/模式）
- **每个目标每分钟最多 2 次**（`agentWakeLog`），防止反复催同一个人 → 连发 → 触发 QQ 风控
- 不能唤醒自己所在的会话

**新增工具**：`qq_wake_peer(key, token, targetKey, reason?)`，开关 `socialV2.tools.wakePeer`。
MCP 工具数 25 → 26。

**实测**：agent token 调 wake 不再 403，目标不在白名单时返回「目标不在当前模式允许范围内」。
