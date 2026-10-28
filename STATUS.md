# STATUS —— 当前状态快照（2026-10-28 21:00）

> 这份文件是「压缩上下文」用的交接文档：只写**现在是什么状态、怎么来的、下一步做什么**。
> 改动原理、踩坑细节在 [FORK-NOTES.md](./FORK-NOTES.md)。

## 一、现在能用吗

**能用**（2026-10-28 20:42 快照）：

```
QQ 小号 1162470069「大肥鱼」   在线
桥（qq-bridge）              connected · online · degraded=false
模式                        reserved2（二代仿真）
角色                        小鲸鱼（5946 字角色卡，active）
ownerQQ                     [OWNER_QQ]（爸爸）
白名单                      [OWNER_QQ], [PEER_QQ]
桥 ↔ DSH                    dshReady=true
```

⚠️ **账号刚经历过风控**（`serverErrorCode: 168`），今天被踢过 3 次（13:34 / 18:15 / 19:30）。风险仍在，见第五节。

## 二、服务拓扑

| 组件 | 位置 | 管理方式 |
|---|---|---|
| NapCat（协议端） | Docker `mlikiowa/napcat-docker`（arm64 原生） | `docker restart napcat`（重启后要扫码） |
| NapCat WebUI | `http://127.0.0.1:6099/webui`（token 见 `~/qq-bridge-napcat/config/webui.json`） | 扫码登录 / OneBot 配置 |
| 桥 | `~/Documents/.../qq-bridge-fork`，launchd `com.local.qq-bridge` | `launchctl kickstart -k gui/$(id -u)/com.local.qq-bridge` |
| 桥控制台 | `http://127.0.0.1:3100/?token=$(cat state/console-token)` | 模式/角色/白名单/花费看板 |
| watcher | launchd `com.local.qq-bridge-watch`，`scripts/auto-resync.mjs` | 每 15 秒探测 DSH 端口漂移，自动重写 config + 重启桥 |
| DSH 桌面版 | Host API 端口**每次启动都变**（本次 62888） | watcher 自动跟 |

DSH 重启后**不用手动做任何事**（watcher 会把桥拉过去）。

## 三、关键配置（`config.json`，都是改过的）

```jsonc
{
  "sessionCwd": "~/.dsh/qq-workspace",     // 让 Hindsight bank 与代码仓库隔离
  "allow": { "private": [OWNER_QQ, PEER_QQ], "groups": [] },
  "allowAllWhenEmpty": true,
  "ownerQQ": [OWNER_QQ],
  "ackMessage": "🤔 收到，正在思考…",       // 发消息后先给个回执

  "socialV2": {
    "agentPreset": "qq-chat-v2",
    "sessionRecycleIdleMs": 600000,        // 闲置 10 分钟退役会话（防上下文涨到 compaction）
    "hindsight": { "enabled": true, "bankId": "coding-agent::qq-workspace", "maxItems": 3, "maxTokens": 400 },
    "context": { "wakeMessageLimit": 6, "wakeRecentLimit": 2, "wakeMaxChars": 2500 },
    "send": { "burstMaxMessages": 8, "maxSendPerMinute": 8, "maxSendPerHour": 60 },  // 已调回上游默认
    "proactive": { "checkIntervalMinMs": 600000, "checkIntervalMaxMs": 1800000,
                   "idleThresholdMs": 600000, "probability": 0.5 },   // 10~30 分钟一次，50% 开口
    "tools": { "memory": false, "sendBurst": false, "status": false,
               "sendGroupLegacy": false, "sendPrivateLegacy": false }  // 关掉的工具
  }
}
```

## 四、改了什么（本仓库，13 个文件未提交）

**代码**
- `src/bridge.js`：闲置会话回收（独立 60s 定时器）、回合结束自动推已读水位、Hindsight 记忆预取（含噪声过滤+主语标注）、好友备注注入、唤醒模板精简、agent 可请求唤醒他人（频控）
- `src/mcp-snowluma-safe.js`：3 个重复工具补开关、新增 `qq_wake_peer` 工具（25→26 个）
- `src/sticker-lib.js`：表情包策略 400→110 字
- `plugins/qq-agent-presets/qq-tool-restrict.mjs`：放行 5 个 Hindsight 工具 + MCP 工具短名（修了"qq_send_message 被当成不在白名单"的 bug）

**preset**（改完要 `node scripts/build-agent-preset-patches.mjs`）
- `dsh/agent-presets/qq-chat-v2/agent.cordis.yml`：记忆改 Hindsight、加【时间感】三档、【每次被唤醒后怎么做】、【首次接入】

**新增文件**
- `start.sh`（守护启动）、`qr.sh`（取二维码）、`resync.sh`（手动重同步）
- `scripts/auto-resync.mjs`（watcher）、`scripts/detect-dsh-port.mjs`（端口发现）
- `FORK-NOTES.md`（改动原理 + 踩坑）、本文件

## 五、踩过的坑（别重复）

1. **掉线主因不是"协议端被识别"，是"连续发消息"**：18:10 连发 5 条给同一对象 → 18:15 被踢。风控看的是行为。
2. **改 `state/*.json` 必须等桥进程完全退出**，否则桥退出前落盘会覆盖你的修改。
3. **改 bridge.js 用 launchctl kickstart 即可；改 preset / MCP / guard 必须重启 DSH。**
4. **DSH 端口每次启动都变**（桌面版），所以有 watcher；`verify:adaptation` 脚本硬编码查 `profiles/web`，我们是 `desktop`，它的 profile 类断言会误报。
5. **Hindsight 会把桥注入的 prompt 当事实抽取**（包括明文会话令牌），所以召回侧有正则过滤；入库侧没有钩子，只能"召回时顺手删"。
6. **不要用宽泛正则删记忆**——`\btoken\b` 会误删"发送失败：agent token 无效"这类真实记录。
7. **会话级令牌隔离**：AI 在 A 的会话里不能给 B 发消息，想找别人说话要用 `qq_wake_peer` 请求唤醒对方会话。

## 六、待办

| 项 | 状态 |
|---|---|
| **git 提交 13 个文件** | ⬜ 一天的改动还没版本保护 |
| preset 瘦身（6500 字 → 3000 字） | ⬜ 用户说"先聊两天再看" |
| 群聊验证 | ⬜ 小号 0 个群 |
| 记忆库 6 条模板噪声 | ⬜ 读侧已过滤，不影响行为 |
| `token 自愈失败` 日志刷屏 | ⬜ 我们不用 SnowLuma 配置目录，可静音 |
| 发送失败自动重启容器 | ⬜ 今天 17:32 通道断了 2 小时没人发现 |

## 七、灰度的东西（别当稳定）

- **账号风控**：已吃 168，掉线 3 次。再被踢就不是配置问题了。
- **主动找人的能力**（`qq_wake_peer`）刚加，**没在真实对话里验证过**。
- **角色卡**刚启用，实际语气效果未验证。
- **Hindsight 记忆**：写入是自动的、读取是桥预取的，都验证过链路，但"记得准不准"要聊几天才知道。
