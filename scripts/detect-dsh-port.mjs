#!/usr/bin/env node
/**
 * 自动发现本机 DSH Host API 的端口并（可选）写回 config.json。
 *
 * 背景：桥接默认连 `dsh web` 的固定端口 3080，但 **DSH 桌面版**的 Host API 端口
 * 每次启动都会变（Electron 内部服务，随机端口）。桌面版对 `GET /` 返回 401，
 * 所以探活必须走带鉴权的 RPC（settings.describe），而不是简单 HTTP 探测。
 *
 * 用法：
 *   node scripts/detect-dsh-port.mjs            # 只探测并打印
 *   node scripts/detect-dsh-port.mjs --write    # 探测成功后写回 config.json
 *   node scripts/detect-dsh-port.mjs --write --quiet
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { NodeApiClient, unwrap } from '../src/dsh-client.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const CONFIG = path.join(ROOT, 'config.json');

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
const log = (...a) => { if (!QUIET) console.log(...a); };
let QUIET = false;

/** 列出本机 LISTEN 端口，最可能是 DSH 的排在前面。 */
export function candidatePorts() {
  const ports = [];
  const push = (p) => {
    const n = Number(p);
    if (Number.isInteger(n) && n > 0 && n < 65536 && !ports.includes(n)) ports.push(n);
  };

  // 1) 配置里已有的端口优先试（避免误连到别的实例）
  try {
    const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
    const m = /:(\d+)/.exec(cfg?.dsh?.baseUrl ?? '');
    if (m) push(m[1]);
  } catch { /* 没有 config.json 就算了 */ }

  // 2) 环境变量
  const env = /:(\d+)/.exec(process.env.DSH_BASE_URL ?? '');
  if (env) push(env[1]);

  // 3) dsh web 的约定端口
  push(3080);

  // 4) lsof：找 DeepSeek Harness / dsh 进程监听的回环端口
  try {
    const out = execFileSync('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN'], { encoding: 'utf8', timeout: 8000 });
    for (const line of out.split('\n')) {
      if (!/DeepSeek|dsh/i.test(line)) continue;
      if (!/127\.0\.0\.1|\[::1\]|\*:/.test(line)) continue;
      const m = /:(\d+)\s+\(LISTEN\)/.exec(line);
      if (m) push(m[1]);
    }
  } catch { /* lsof 不可用就跳过 */ }

  return ports;
}

/** 用带鉴权的 RPC 探一个端口是不是 DSH Host API。 */
export async function probe(port) {
  const baseUrl = `http://127.0.0.1:${port}`;
  const api = new NodeApiClient(baseUrl, 8000, {});
  try {
    const desc = unwrap(await api.settings.describe({}), 'settings.describe');
    const ns = Array.isArray(desc?.namespaces) ? desc.namespaces.length : 0;
    return { ok: true, baseUrl, namespaces: ns, writable: desc?.writable === true };
  } catch (error) {
    return { ok: false, baseUrl, error: error?.message ?? String(error) };
  }
}

/**
 * 探测并（可选）写回。供 CLI 与 auto-resync 复用。
 * @param options.write - 命中后是否写回 config.json。
 * @param options.quiet - 不打印。
 * @param options.ports - 候选端口（默认自动枚举）。
 * @returns 命中的 { baseUrl, namespaces, writable }，未命中返回 null。
 */
export async function detect({ write = false, quiet = false, ports = null } = {}) {
  QUIET = quiet;
  const candidates = ports ?? candidatePorts();
  log(`候选端口: ${candidates.join(', ')}`);
  let found = null;
  for (const port of candidates) {
    const r = await probe(port);
    if (r.ok) {
      log(`✅ 命中 DSH Host API: ${r.baseUrl}（namespace ${r.namespaces} 个，writable=${r.writable}）`);
      found = r;
      break;
    }
    log(`   ${r.baseUrl} → ${r.error}`);
  }
  if (!found) return null;
  if (write) writeBaseUrl(found.baseUrl);
  return found;
}

/**
 * 把 baseUrl 写回 config.json（仅在变化时写，保留原有格式）。
 * @returns {{updated: boolean, from: string|null, to: string}}
 */
export function writeBaseUrl(baseUrl) {
  let text = fs.readFileSync(CONFIG, 'utf8');
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  const cfg = JSON.parse(text);
  const from = cfg.dsh?.baseUrl ?? null;
  if (from === baseUrl) return { updated: false, from, to: baseUrl };
  cfg.dsh ??= {};
  cfg.dsh.baseUrl = baseUrl;
  fs.writeFileSync(CONFIG, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
  log(`✅ 已写回 config.json：dsh.baseUrl ${from ?? '(未设置)'} → ${baseUrl}`);
  return { updated: true, from, to: baseUrl };
}

const isCli = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isCli) {
  const args = new Set(process.argv.slice(2));
  const found = await detect({ write: args.has('--write'), quiet: args.has('--quiet') });
  if (!found) {
    console.error('❌ 没找到可用的 DSH Host API。请确认 DSH 正在运行，或用 DSH_BASE_URL 指定。');
    process.exit(1);
  }
  if (!args.has('--write')) log('（加 --write 可写回 config.json 的 dsh.baseUrl）');
}
