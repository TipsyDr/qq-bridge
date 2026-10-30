#!/usr/bin/env node
/**
 * 删除 DSH 的「已归档会话」。
 *
 * 为什么需要单独一个脚本：归档只是把 sessionId 记进
 *   ~/.dsh/storages/workspace.json → global.archivedSessionIds
 * 会话目录本身还在磁盘上（~/.dsh/sessions/<workspace>/session-<uuid>/）。
 * 手动 rm 目录会留下悬空 id，DSH 列表里出现点不开的鬼条目；反过来只改 json
 * 不改目录则是白占空间。
 *
 * 正确做法是走 DSH 自己的 RPC（`session.remove`），让它同时清索引与落盘文件。
 * qq-bridge 的 dsh-client 已经会铸造浏览器会话 cookie，直接复用。
 *
 * 背景：qq-bridge 的闲置回收（sessionRecycleIdleMs）每次退役都归档一个会话，
 * 一天下来 QQ 工作区就攒了 63 个归档 —— 这就是「归档的对话」的来源。
 *
 * 用法：
 *   node scripts/purge-archived-sessions.mjs             # 干跑，只列表
 *   node scripts/purge-archived-sessions.mjs --apply     # 真删
 *   node scripts/purge-archived-sessions.mjs --apply --keep-qq   # 保留 QQ 工作区的
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { NodeApiClient } from '../src/dsh-client.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const WORKSPACE_JSON = path.join(DSH_HOME, 'storages', 'workspace.json');
const SESSIONS_DIR = path.join(DSH_HOME, 'sessions');

const args = process.argv.slice(2);
const APPLY = args.includes('--apply');
const KEEP_QQ = args.includes('--keep-qq');

const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config.json'), 'utf8'));
const baseUrl = cfg?.dsh?.baseUrl || 'http://127.0.0.1:3080';

// ── 归档清单 ────────────────────────────────────────────────────────────────
const store = JSON.parse(fs.readFileSync(WORKSPACE_JSON, 'utf8'));
const archived = [...new Set(store?.global?.archivedSessionIds ?? [])];

/** sessionId → 磁盘上的会话目录（用于算体积、删残骸） */
function indexSessionDirs() {
  const map = new Map();
  for (const ws of fs.readdirSync(SESSIONS_DIR)) {
    const dir = path.join(SESSIONS_DIR, ws);
    if (!fs.statSync(dir).isDirectory()) continue;
    for (const sid of fs.readdirSync(dir)) {
      const full = path.join(dir, sid);
      if (!fs.statSync(full).isDirectory()) continue;
      const size = (function walk(p) {
        let n = 0;
        for (const e of fs.readdirSync(p, { withFileTypes: true })) {
          const q = path.join(p, e.name);
          n += e.isDirectory() ? walk(q) : fs.statSync(q).size;
        }
        return n;
      })(full);
      map.set(sid, { dir: full, workspace: ws, size });
    }
  }
  return map;
}

const dirs = indexSessionDirs();
const targets = archived.filter((sid) => {
  if (!KEEP_QQ) return true;
  const info = dirs.get(sid);
  return !(info?.workspace.includes('qq-workspace'));
});

const totalBytes = targets.reduce((n, sid) => n + (dirs.get(sid)?.size ?? 0), 0);
const byWs = {};
for (const sid of targets) {
  const ws = dirs.get(sid)?.workspace ?? '（磁盘上已不存在）';
  byWs[ws] = (byWs[ws] ?? 0) + 1;
}

console.log(`归档总数: ${archived.length}    本次目标: ${targets.length}    占用: ${(totalBytes / 1e6).toFixed(1)} MB`);
console.log(`DSH: ${baseUrl}`);
for (const [ws, n] of Object.entries(byWs).sort((a, b) => b[1] - a[1])) console.log(`  ${ws}  ${n}`);

if (!APPLY) {
  console.log('\n干跑结束。加 --apply 才真删（走 session.remove，索引与文件一起清）。');
  process.exit(0);
}

// ── 真删 ────────────────────────────────────────────────────────────────────
// 先备份索引，出问题能回滚
const backup = `${WORKSPACE_JSON}.bak-${new Date().toISOString().replace(/[:.]/g, '-')}`;
fs.copyFileSync(WORKSPACE_JSON, backup);
console.log(`\n已备份索引 → ${path.basename(backup)}`);

const api = new NodeApiClient(baseUrl, undefined, { token: cfg?.dsh?.authToken ?? '', header: cfg?.dsh?.authHeader, prefix: cfg?.dsh?.authPrefix, allowRemote: false });
try { await api.ensureAuth(); } catch (error) {
  console.error(`连不上 DSH（${baseUrl}）：${error?.message ?? error}`);
  process.exit(1);
}

let ok = 0; let fail = 0;
for (const sid of targets) {
  let removed = false;
  for (const method of ['session.remove', 'session/remove']) {
    try {
      const r = await api.callUnary(method, { sessionId: sid });
      if (r) { removed = true; break; }
    } catch { /* 换下一个方法名再试 */ }
  }
  // RPC 不成也要把残骸清掉，否则索引删了空间还占着
  const info = dirs.get(sid);
  if (info && fs.existsSync(info.dir)) {
    try { fs.rmSync(info.dir, { recursive: true, force: true }); removed = true; } catch {}
  }
  if (removed) ok++; else fail++;
  if ((ok + fail) % 20 === 0) process.stdout.write(`  已处理 ${ok + fail}/${targets.length}\r`);
}
console.log(`\n删除完成：成功 ${ok}，失败 ${fail}`);

// 兜底：把 id 从索引里摘掉（DSH 可能已自己更新，重复摘是幂等的）
try {
  const s = JSON.parse(fs.readFileSync(WORKSPACE_JSON, 'utf8'));
  const before = (s?.global?.archivedSessionIds ?? []).length;
  const gone = new Set(targets);
  s.global.archivedSessionIds = (s.global.archivedSessionIds ?? []).filter((id) => !gone.has(id));
  fs.writeFileSync(WORKSPACE_JSON, JSON.stringify(s), 'utf8');
  console.log(`索引：archivedSessionIds ${before} → ${s.global.archivedSessionIds.length}`);
} catch (error) {
  console.error(`索引收尾失败（可还原 ${path.basename(backup)}）：${error?.message ?? error}`);
}
