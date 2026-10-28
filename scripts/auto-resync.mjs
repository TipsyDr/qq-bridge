#!/usr/bin/env node
/**
 * auto-resync —— 让 qq-bridge 在 DSH 重启后自己跟上，不需要人跑 resync.sh。
 *
 * 背景：DSH 桌面版的 Host API 端口每次启动都会变（Electron 内部服务，随机端口），
 * 而桥只在启动时读一次 config.json 里的 `dsh.baseUrl`。于是「重启 DSH」= 桥失联，
 * 以前得手动跑 resync.sh。
 *
 * 本进程常驻（launchd KeepAlive），每 15 秒做一次判断：
 *   1. config.json 里的 baseUrl 还可达吗？可达就什么都不做（不写文件、不打日志）；
 *   2. 不可达 → 重新枚举候选端口，用带鉴权的 RPC 探活；
 *   3. 探到新端口 → 写回 config.json → `launchctl kickstart` 重启桥，让桥读到新端口。
 *
 * 只在**状态变化**时打日志，避免每 15 秒刷一行。
 *
 * 用法：node scripts/auto-resync.mjs [--once]
 *   RESYNC_INTERVAL_MS=15000  探测间隔（最小 5000）
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { candidatePorts, detect, probe, writeBaseUrl } from './detect-dsh-port.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const CONFIG = path.join(ROOT, 'config.json');
const BRIDGE_LABEL = process.env.BRIDGE_LABEL || 'com.local.qq-bridge';
const ONCE = process.argv.includes('--once');
const INTERVAL = Math.max(5000, Number(process.env.RESYNC_INTERVAL_MS ?? 15000) || 15000);

const stamp = () => new Date().toISOString().replace('T', ' ').slice(0, 19);
const log = (message) => console.log(`[${stamp()}] ${message}`);

/** 读当前配置里的 baseUrl 与其端口。 */
function currentTarget() {
  try {
    const text = fs.readFileSync(CONFIG, 'utf8');
    const cfg = JSON.parse(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
    const baseUrl = String(cfg?.dsh?.baseUrl ?? '');
    const match = /:(\d+)/.exec(baseUrl);
    return { baseUrl, port: match ? Number(match[1]) : 0 };
  } catch {
    return { baseUrl: '', port: 0 };
  }
}

/** 重启桥（launchd）。失败只告警，不退出：下次循环还会再试。 */
function kickstartBridge() {
  try {
    execFileSync('launchctl', ['kickstart', '-k', `gui/${process.getuid()}/${BRIDGE_LABEL}`], { timeout: 10000 });
    log(`已 kickstart ${BRIDGE_LABEL}（桥会用新端口重连）`);
    return true;
  } catch (error) {
    log(`⚠️ kickstart ${BRIDGE_LABEL} 失败：${error?.message ?? error}（确认 launchctl list | grep qq-bridge）`);
    return false;
  }
}

/** 一轮判断。 */
async function tick(state) {
  const { baseUrl, port } = currentTarget();
  if (!baseUrl || !port) {
    if (state.last !== 'noconfig') {
      log('⚠️ config.json 里没有 dsh.baseUrl，先跑一次 detect-dsh-port.mjs --write');
      state.last = 'noconfig';
    }
    return;
  }

  const mine = await probe(port);
  if (mine.ok) {
    if (state.last !== 'ok') {
      log(`DSH 可达：${baseUrl}（保持不变）`);
      state.last = 'ok';
    }
    return;
  }

  // 当前端口不通：可能是 DSH 正在重启，也可能换了端口
  const found = await detect({ write: false, quiet: true, ports: candidatePorts() });
  if (!found) {
    if (state.last !== 'down') {
      log(`DSH 不可达（${baseUrl} 连不上），且没在候选端口上找到新的 Host API —— 等下一轮`);
      state.last = 'down';
    }
    return;
  }
  if (found.baseUrl === baseUrl) {
    state.last = 'down';
    return;
  }
  log(`检测到 DSH 换端口：${baseUrl} → ${found.baseUrl}`);
  const result = writeBaseUrl(found.baseUrl);
  if (result.updated) {
    kickstartBridge();
    state.last = 'moved';
  }
}

const state = { last: '' };
log(`auto-resync 启动：每 ${INTERVAL / 1000}s 检查一次（${BRIDGE_LABEL}）`);
for (;;) {
  try {
    await tick(state);
  } catch (error) {
    log(`⚠️ 本轮出错：${error?.message ?? error}`);
  }
  if (ONCE) break;
  await new Promise((resolve) => setTimeout(resolve, INTERVAL));
}
