#!/usr/bin/env node
/**
 * Hindsight 记忆策展：把「噪声」记忆真正失效掉，而不是每次唤醒用正则挡。
 *
 * 为什么需要这个脚本而不是在桥接里加过滤器：
 *   Hindsight 本来有失效机制 —— `PATCH /memories/{id}` 带 `state: 'invalidated'`
 *   会把记忆软下线（排除出 recall 与 consolidation，链接与派生 observation 一并清理，
 *   移入 archive），`state: 'valid'` 可回滚。这比「再写一条纠偏记忆去压旧记忆」干净得多：
 *   前者是从库里移走错误断言，后者只是往库里再加一条，越加越乱。
 *
 *   实测（2026-10-29）三类内容占了全库 ~45%：令牌/模式说明、已读水位/潜水/seq 记账、
 *   身份样板。它们条条带当前对话对象的 QQ 号，在召回里永远霸占前排，把真正的内容挤没。
 *
 * 一个坑：`observation` 类型**不能**直接失效
 *   （400: "is a observation; only world/experience facts can be curated.
 *    Observations are derived and regenerate from their sources."）
 *   observation 是抽取出来的派生结论，只能顺着 source_fact_ids 去失效它的事实来源。
 *   这个脚本会自动这么做。
 *
 * 用法：
 *   node scripts/hindsight-curate.mjs                 # 干跑，只统计不写
 *   node scripts/hindsight-curate.mjs --apply         # 真失效
 *   node scripts/hindsight-curate.mjs --apply --class noise
 *   node scripts/hindsight-curate.mjs --restore --class noise   # 反悔：置回 valid
 *
 * 环境变量：HINDSIGHT_PORT（默认 9077）、HINDSIGHT_BANK（默认 coding-agent::qq-workspace）
 */

const PORT = Number(process.env.HINDSIGHT_PORT) || 9077;
const BANK = process.env.HINDSIGHT_BANK || 'coding-agent::qq-workspace';
const BASE = `http://127.0.0.1:${PORT}/v1/default/banks/${encodeURIComponent(BANK)}`;

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const val = (f, d) => { const i = args.indexOf(f); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const APPLY = has('--apply');
const RESTORE = has('--restore');
const ONLY = val('--class', 'all');
const LIMIT = Number(val('--limit', '0')) || Infinity;

// ── 分类规则（与 src/bridge.js 的读侧过滤保持一致）────────────────────────────
// 只算「提示词漏进库」的纯噪声；聊到 token 的真实对话不算（旧规则误伤过）。
const NOISE = /会话令牌 *[:：为是]|状态令牌 *[:：为是]|调用二代状态工具时|二代仿真模式（reserved2）|(?<![0-9a-f])[0-9a-f]{32,}(?![0-9a-f])/i;
const BOOK = /readThroughSeq|已读水位|未读 *\d+ *条|会话状态：截至|等满 *\d+ *分钟|等 *\d+ *秒无人回复|潜水|唤醒配置|概率 *0?\.\d|mode=diving|seq *\d+|主动冒泡|旧账|throughSeq/i;
const BOIL = /昵称是|群名片可能与昵称不同|称呼助手为|身份是管理员|需要通过 SnowLuma 网关发送消息的联系人|主要用于私聊与机器人交互|指该智能体本人|会话标识为|机器人账号的管理员|owner）是|就是「爸爸」/;

const classify = (t) => (NOISE.test(t) ? 'noise' : BOOK.test(t) ? 'book' : BOIL.test(t) ? 'boil' : 'keep');
const wanted = (c) => ONLY === 'all' ? c !== 'keep' : c === ONLY;

const REASON = {
  noise: 'curation: prompt noise (session token / mode instructions) — has no conversational value and may leak secrets',
  book: 'curation: operational bookkeeping (read watermark / sleep config / seq) — regenerated from live state, pollutes recall',
  boil: 'curation: identity boilerplate — already known, occupies recall slots that should hold news',
};

async function listAll() {
  const out = [];
  for (let off = 0; off < 5000; off += 100) {
    const res = await fetch(`${BASE}/memories/list?limit=100&offset=${off}`, { signal: AbortSignal.timeout(15000) });
    if (!res.ok) throw new Error(`list ${res.status}`);
    const items = (await res.json()).items || [];
    out.push(...items);
    if (items.length < 100) break;
  }
  return out;
}

async function detail(id) {
  const res = await fetch(`${BASE}/memories/${encodeURIComponent(id)}`, { signal: AbortSignal.timeout(15000) });
  if (!res.ok) return null;
  return res.json();
}

async function patch(id, body) {
  const res = await fetch(`${BASE}/memories/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  return { ok: res.ok, status: res.status, text: await res.text() };
}

const all = await listAll();
const stats = { noise: 0, book: 0, boil: 0, keep: 0 };
const targets = [];
for (const m of all) {
  const c = classify(String(m.text || ''));
  stats[c] = (stats[c] || 0) + 1;
  if (wanted(c)) targets.push({ id: m.id, text: String(m.text || ''), cls: c });
}

console.log(`bank: ${BANK}`);
console.log(`全库 ${all.length} 条 → noise ${stats.noise} / book ${stats.book} / boil ${stats.boil} / keep ${stats.keep}`);
console.log(`本次目标（class=${ONLY}）: ${targets.length} 条  ${APPLY ? '【真写】' : RESTORE ? '【恢复】' : '【干跑】'}`);
if (!APPLY && !RESTORE) {
  for (const t of targets.slice(0, 12)) console.log(`  · [${t.cls}] ${t.text.slice(0, 90)}`);
  console.log('\n加 --apply 才真的失效。');
  process.exit(0);
}

let done = 0, viaSource = 0, failed = 0, skipped = 0;
for (const t of targets.slice(0, LIMIT === Infinity ? undefined : LIMIT)) {
  const body = RESTORE
    ? { state: 'valid' }
    : { state: 'invalidated', reason: REASON[t.cls] };
  const r = await patch(t.id, body);
  if (r.ok) { done++; continue; }
  if (!RESTORE && r.text.includes('observation')) {
    // observation 不能直接改：顺着 source_fact_ids 去失效来源事实
    const d = await detail(t.id);
    const srcIds = Array.isArray(d?.source_fact_ids) ? d.source_fact_ids : [];
    if (srcIds.length === 0) { skipped++; continue; }
    let touched = 0;
    for (const sid of srcIds) {
      const rr = await patch(sid, body);
      if (rr.ok) touched++;
    }
    touched > 0 ? (viaSource += touched, done++) : skipped++;
    continue;
  }
  failed++;
  if (failed <= 3) console.log(`  ✗ ${r.status} ${String(t.text).slice(0, 60)} → ${r.text.slice(0, 120)}`);
}

console.log(`\n完成：直接失效 ${done - viaSource} 条，经 source_fact_ids 失效 ${viaSource} 条，跳过 ${skipped}，失败 ${failed}`);
console.log('要回滚：node scripts/hindsight-curate.mjs --restore --class <同上>');
