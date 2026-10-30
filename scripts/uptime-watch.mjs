#!/usr/bin/env node
/**
 * 记录「登录 → 被踢」的存活时长，用来做协议端/账号的对照。
 *
 * 为什么需要：现在判断「是不是风控」全靠肉眼翻 docker logs 拼时间线。
 * 2026-10-29 那天三次被踢（3分22秒 / 2小时15分 / 39分钟）是我事后一条条 grep 出来的，
 * 而且 NapCat 容器一重建，历史日志就没了。没有连续记录，就没法回答
 * 「换协议端值不值」「是不是该换号」这类问题。
 *
 * 做法：盯要看的容器日志（docker logs --since 起算，增量读），
 * 认出「登录成功 / 被踢下线」两类事件，把每段的时长追加到 logs/uptime.tsv。
 *
 * 用法：
 *   node scripts/uptime-watch.mjs                    # 盯 snowluma（默认）
 *   node scripts/uptime-watch.mjs --container napcat
 *   node scripts/uptime-watch.mjs --once             # 只扫一遍当前日志就退出
 *
 * 产物：logs/uptime.tsv —— protocol / login_at / kicked_at / seconds / note
 */

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT = path.join(ROOT, 'logs', 'uptime.tsv');
const STATE = path.join(ROOT, 'logs', '.uptime-state.json');

const args = process.argv.slice(2);
const argVal = (k, d) => { const i = args.indexOf(k); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const CONTAINER = argVal('--container', 'snowluma');
const ONCE = args.includes('--once');
const POLL_MS = Number(argVal('--interval', '60000'));
// 首次运行回看多久的日志（默认 6 小时）。不然只会从「现在」开始看，
// 上一次登录已经过去十分钟就抓不到了 —— 实测第一次跑就是空表。
const LOOKBACK_SEC = Number(argVal('--lookback', String(6 * 3600)));

// 「上线」与「被踢」的特征串（SnowLuma 与 NapCat 两套都认）
const LOGIN_RE = /session started|账号状态变更为在线|自动快速登录成功|\[OneBot\] network startup applied/i;
const KICK_RE = /kicked|被踢|下线通知|账号状态变更为离线|登录已失效|Login Error/i;

fs.mkdirSync(path.join(ROOT, 'logs'), { recursive: true });
if (!fs.existsSync(OUT)) {
  fs.writeFileSync(OUT, 'protocol\tlogin_at\tkicked_at\tseconds\tnote\n', 'utf8');
}

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return { since: 0, seenLines: 0 }; }
}
function writeState(s) { fs.writeFileSync(STATE, JSON.stringify(s), 'utf8'); }

/** 取容器日志（带时间戳、去 ANSI）。首次按容器创建时间取全量。 */
function fetchLogs(sinceSec) {
  const since = sinceSec > 0
    ? new Date(sinceSec * 1000).toISOString().replace(/\.\d+Z$/, 'Z')
    : null;
  const argv = ['logs', '--timestamps'];
  if (since) argv.push('--since', since);
  argv.push(CONTAINER);
  // 必须用 spawnSync 同时收两路：容器日志是 stdout，但 docker 自己/某些进程会写 stderr，
  // 只读 stdout 会漏（实测第一次跑就是空表，而原始日志居然被继承到终端打印出来）。
  const r = spawnSync('docker', argv, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return `${r.stdout ?? ''}${r.stderr ?? ''}`;
}

const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

/** 把日志切成 [{ts, line}]，ts 是 ISO 字符串行首那个。 */
function parseLines(raw) {
  const out = [];
  for (const line of raw.split('\n')) {
    const m = /^(\d{4}-\d{2}-\d{2}T[\d:.]+Z)\s?(.*)$/.exec(line);
    if (m) out.push({ ts: m[1], text: stripAnsi(m[2]) });
  }
  return out;
}

let state = readState();
const nowSec = Math.floor(Date.now() / 1000);
if (!state.since) { state.since = nowSec - LOOKBACK_SEC; writeState(state); }

function scanOnce() {
  const lines = parseLines(fetchLogs(state.since));
  const fresh = lines.slice(state.seenLines ?? 0);
  if (fresh.length === 0) return 0;

  const rows = [];
  for (const { ts, text } of fresh) {
    if (LOGIN_RE.test(text)) rows.push({ kind: 'login', ts });
    else if (KICK_RE.test(text)) rows.push({ kind: 'kick', ts });
  }
  state.seenLines = lines.length;
  writeState(state);
  if (rows.length === 0) return 0;

  // 配对：login 之后最近的 kick 算一段；未配对的 login 记成「进行中」
  let lastLogin = null;
  let appended = 0;
  for (const r of rows) {
    if (r.kind === 'login') { lastLogin = r.ts; continue; }
    if (!lastLogin) continue;
    const sec = Math.round((Date.parse(r.ts) - Date.parse(lastLogin)) / 1000);
    const note = sec < 300 ? '短命(<5min)' : sec < 3600 ? '短(<1h)' : '较长(>=1h)';
    fs.appendFileSync(OUT, `${CONTAINER}\t${lastLogin}\t${r.ts}\t${sec}\t${note}\n`, 'utf8');
    console.log(`[uptime] ${CONTAINER} 存活 ${sec}s（${note}）: ${lastLogin} → ${r.ts}`);
    lastLogin = null;
    appended++;
  }
  if (lastLogin) console.log(`[uptime] ${CONTAINER} 当前这段从 ${lastLogin} 开始，仍在计时`);
  return appended;
}

if (ONCE) {
  scanOnce();
  console.log(`[uptime] 结果写入 ${path.relative(ROOT, OUT)}`);
  process.exit(0);
}

console.log(`[uptime] 开始盯 ${CONTAINER}，每 ${POLL_MS / 1000}s 扫一次 → ${path.relative(ROOT, OUT)}`);
scanOnce();
setInterval(() => {
  try { scanOnce(); } catch (error) { console.error('[uptime] 扫描失败:', error?.message ?? error); }
}, POLL_MS);
