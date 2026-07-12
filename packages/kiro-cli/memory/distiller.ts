// kiro-cli auto-memory distiller (Stop-hook, debounced).
//
// Reads kiro's on-disk session transcript (messages.jsonl), extracts the turns
// completed since the last run, formats them into the tiered file buffer
// (~/.kiro-memory/<slug>/), and hands the raw turn text to a pluggable memory
// backend (openmemory SDK, wired later). No LLM on the hot path: "distillation"
// here is deterministic extraction + formatting, not summarization.
//
// Ground-truth messages.jsonl schema (kiro-cli 2.11.1, verified S7): each line is
// {id, payload, timestamp}; the discriminator is `payload.type`. A turn is
//   user (no executionId) -> turn_start(execId) -> assistant*(execId) -> turn_end(execId)
// with the user prompt associated positionally (it precedes turn_start).

import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

export interface Turn {
  /** turn_start.executionId — the turn key. */
  execId: string;
  /** raw user prompt string, or null if the turn had no preceding user message. */
  userPrompt: string | null;
  /** concatenated assistant `Say` content (Reasoning is excluded as internal CoT). */
  assistantSay: string;
  /** tools kiro reported using this turn (from usage_summary.promptTurnSummaries). */
  usedTools: string[];
  startTs: string | null;
  endTs: string | null;
  /** true once a matching turn_end was seen. */
  complete: boolean;
}

/**
 * The complete turns from a transcript that have not yet been distilled.
 * Dedup is by turn execId (stable turn key) rather than a line offset, so a turn
 * whose turn_start was already seen but whose turn_end only just arrived is still
 * picked up exactly once. Incomplete (in-flight) turns are never returned.
 */
export function selectUndistilledTurns(
  lines: string[],
  distilled: Set<string>,
): Turn[] {
  return parseTranscript(lines).filter(
    (t) => t.complete && !distilled.has(t.execId),
  );
}

/**
 * The memory scope key (D19). Derived from the CANONICAL repo root — the parent of
 * `git --git-common-dir`, which resolves to the MAIN repo's .git for every linked
 * worktree, so all worktrees of one repo share a project_id. A short hash of the
 * full root path is appended to keep same-basename repos from colliding while
 * staying human-readable. Non-git cwd falls back to the cwd itself.
 */
function slugify(s: string): string {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "repo"
  );
}

export function deriveProjectId(
  gitCommonDir: string | null,
  cwd: string,
): string {
  const root = gitCommonDir ? dirname(gitCommonDir) : cwd;
  const hash = createHash("sha256").update(root).digest("hex").slice(0, 8);
  return `${slugify(basename(root))}-${hash}`;
}

/** Persisted per-session distiller state (in ~/.kiro-memory/<slug>/.state/<session>.json). */
export interface DistillState {
  /** transcript line count at the last distill run (debounce line-delta baseline). */
  lastLineCount: number;
  /** transcript byte size at the last distill run — the cheap (stat-only) growth
   * signal flushSessionTails uses to skip caught-up sessions without a full read. */
  lastTranscriptSize: number;
  /** epoch ms of the last distill run (debounce cooldown baseline). */
  lastRunMs: number;
  /** execIds already distilled (extraction dedup). */
  distilled: string[];
}

export interface DebounceOpts {
  /** minimum new transcript lines since last run before distilling again. */
  minNewLines: number;
  /** minimum ms since last run before distilling again. */
  cooldownMs: number;
}

/**
 * Cheap pre-parse debounce gate. Stop fires per-turn (D11), so distill on EITHER
 * signal: enough new lines have accrued (batch while a turn stream is busy) OR the
 * cooldown has elapsed since the last run (flush the tail while quiet). It skips only
 * when BOTH are false — too few new lines AND a recent run — which is the rate-limit.
 *
 * The OR (not AND) is load-bearing (D24): v3 has no SessionEnd hook and Stop is
 * per-turn, so an AND gate silently DROPS a session's final turn whenever it adds
 * fewer than minNewLines. OR flushes that tail once the cooldown passes; the residual
 * (a sub-threshold tail that ends within the cooldown) is caught by flushSessionTails
 * on the next SessionStart, and Manual `force` is the interim catch either way.
 *
 * The third "dirty-flag" signal (are there actually undistilled complete turns?) is
 * evaluated after parsing, only once this gate has passed — see distill().
 */
export function shouldDistill(
  state: Pick<DistillState, "lastLineCount" | "lastRunMs">,
  current: { lineCount: number; nowMs: number },
  opts: DebounceOpts,
): boolean {
  const enoughNew = current.lineCount - state.lastLineCount >= opts.minNewLines;
  const cooledDown = current.nowMs - state.lastRunMs >= opts.cooldownMs;
  return enoughNew || cooledDown;
}

export interface FormatOpts {
  /** truncate the user prompt to this many chars in the buffer block. */
  maxPromptChars?: number;
  /** truncate the assistant answer to this many chars in the buffer block. */
  maxSayChars?: number;
}

/**
 * Render a turn as a compact markdown block for the file buffer. Kept small on
 * purpose — the `now` tier is bulk-loaded into steering, so per-block content is
 * truncated; the full turn text goes to the openmemory archive instead.
 */
function truncate(s: string, n: number): string {
  return s.length <= n ? s : `${s.slice(0, n)}…`;
}

export function formatTurnBlock(turn: Turn, opts: FormatOpts = {}): string {
  const maxPromptChars = opts.maxPromptChars ?? 200;
  const maxSayChars = opts.maxSayChars ?? 600;
  const ts = turn.endTs ?? turn.startTs ?? "";
  const parts: string[] = [`### ${ts}`.trimEnd()];
  if (turn.userPrompt) {
    parts.push(`**Ask:** ${truncate(turn.userPrompt.trim(), maxPromptChars)}`);
  }
  const say = turn.assistantSay.trim();
  if (say) parts.push(truncate(say, maxSayChars));
  if (turn.usedTools.length)
    parts.push(`_tools: ${turn.usedTools.join(", ")}_`);
  return parts.join("\n\n");
}

/** The tiered file buffer, each tier an ordered (oldest-first) list of turn blocks. */
export interface Tiers {
  now: string[];
  recent: string[];
  archive: string[];
}

export interface RollOpts {
  /** max turn blocks kept in `now` (the steering-bulk-loaded tier — keep small). */
  maxNowTurns: number;
  /** max turn blocks kept in `recent` (the warm tier) before spilling to archive. */
  maxRecentTurns: number;
}

/**
 * Append new blocks to `now`, then cascade overflow oldest-first: now -> recent ->
 * archive. `archive` is append-only (the cold tier, also mirrored in openmemory).
 * Pure: returns fresh arrays, never mutates the input.
 */
export function rollTiers(
  tiers: Tiers,
  newBlocks: string[],
  opts: RollOpts,
): Tiers {
  let now = [...tiers.now, ...newBlocks];
  let recent = [...tiers.recent];
  const archive = [...tiers.archive];

  const nowOverflow = now.length - opts.maxNowTurns;
  if (nowOverflow > 0) {
    recent = [...recent, ...now.slice(0, nowOverflow)];
    now = now.slice(nowOverflow);
  }

  const recentOverflow = recent.length - opts.maxRecentTurns;
  if (recentOverflow > 0) {
    archive.push(...recent.slice(0, recentOverflow));
    recent = recent.slice(recentOverflow);
  }

  return { now, recent, archive };
}

interface TranscriptLine {
  payload?: { type?: string; [k: string]: unknown };
  timestamp?: string;
}

export function parseTranscript(lines: string[]): Turn[] {
  const turns: Turn[] = [];
  const byExec = new Map<string, Turn>();
  let pendingUser: string | null = null;

  for (const raw of lines) {
    if (!raw.trim()) continue;
    let rec: TranscriptLine;
    try {
      rec = JSON.parse(raw) as TranscriptLine;
    } catch {
      continue; // skip malformed line
    }
    const p = rec.payload;
    if (!p || typeof p.type !== "string") continue;

    switch (p.type) {
      case "user":
        if (typeof p.content === "string") pendingUser = p.content;
        break;
      case "turn_start": {
        // Consume the pending prompt on ANY turn_start, so a malformed
        // (execId-less) turn_start cannot leak an earlier prompt onto a later turn.
        const userPrompt = pendingUser;
        pendingUser = null;
        const execId = p.executionId as string;
        if (!execId) break;
        const turn: Turn = {
          execId,
          userPrompt,
          assistantSay: "",
          usedTools: [],
          startTs: rec.timestamp ?? null,
          endTs: null,
          complete: false,
        };
        byExec.set(execId, turn);
        turns.push(turn);
        break;
      }
      case "assistant": {
        const turn = byExec.get(p.executionId as string);
        if (
          turn &&
          p.operationType === "Say" &&
          typeof p.content === "string"
        ) {
          turn.assistantSay = turn.assistantSay
            ? `${turn.assistantSay}\n\n${p.content}`
            : p.content;
        }
        break;
      }
      case "usage_summary": {
        const turn = byExec.get(p.executionId as string);
        const summaries = p.promptTurnSummaries;
        if (turn && Array.isArray(summaries)) {
          for (const s of summaries) {
            const tools = (s as { usedTools?: unknown }).usedTools;
            if (Array.isArray(tools)) {
              for (const t of tools as string[]) {
                if (!turn.usedTools.includes(t)) turn.usedTools.push(t);
              }
            }
          }
        }
        break;
      }
      case "turn_end": {
        const turn = byExec.get(p.executionId as string);
        if (turn) {
          turn.complete = true;
          turn.endTs = rec.timestamp ?? null;
        }
        break;
      }
    }
  }

  return turns;
}

// --- orchestration: fs/git wrappers + the top-level distill() ---

/** Full (untruncated) turn text handed to the memory backend for its own extraction. */
export function turnToMemoryText(turn: Turn): string {
  const ask = turn.userPrompt ? `Ask: ${turn.userPrompt.trim()}\n\n` : "";
  return `${ask}${turn.assistantSay.trim()}`.trim();
}

/**
 * Locate a session's transcript by session_id without knowing kiro's workspace-hash
 * algorithm: glob <sessionsDir>/<anyHash>/<sessionId>/messages.jsonl (D12). Returns
 * the first match, or null if none exists.
 */
export function locateTranscript(
  sessionsDir: string,
  sessionId: string,
): string | null {
  let hashes: string[];
  try {
    hashes = readdirSync(sessionsDir);
  } catch {
    return null; // sessions dir missing
  }
  for (const h of hashes) {
    const candidate = join(sessionsDir, h, sessionId, "messages.jsonl");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * The canonical repo root's .git via `git -C <cwd> rev-parse --path-format=absolute
 * --git-common-dir`. Returns the absolute path, or null when cwd is not in a git repo.
 */
export function resolveGitCommonDir(cwd: string): string | null {
  try {
    const out = execFileSync(
      "git",
      ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    );
    return out.trim() || null;
  } catch (e) {
    if ((e as { code?: string }).code === "ENOENT") {
      // git missing on PATH (vs. genuinely-not-a-repo, git exit 128): the cwd
      // fallback would silently break D19's worktree-shared scope, so warn.
      process.stderr.write(
        "[kiro-memory] git not on PATH; memory scope falls back to cwd\n",
      );
    }
    return null;
  }
}

/** A best-effort memory-backend write (openmemory SDK, wired in a later checkpoint). */
export type BackendWrite = (fact: {
  projectId: string;
  content: string;
  turn: Turn;
}) => void;

export interface DistillConfig {
  sessionId: string;
  cwd: string;
  sessionsDir: string;
  memoryDir: string;
  nowMs: number;
  /** resolved git common dir (null = non-git); injected so distill() stays pure of git. */
  gitCommonDir: string | null;
  /** Manual /remember bypasses the debounce gate. */
  force?: boolean;
  debounce: DebounceOpts;
  roll: RollOpts;
  format: FormatOpts;
  /** best-effort backend seam; omitted = file-buffer only. */
  backendWrite?: BackendWrite;
}

export interface DistillResult {
  projectId: string;
  distilled: number;
  skipped: "debounced" | "no-new-turns" | "no-transcript" | null;
}

interface FileBuffer {
  now: string[];
  recent: string[];
}

function writeAtomic(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true });
  // Unique temp name per writer so concurrent worktree distillers writing the same
  // shared path do not clobber each other's temp file mid-write.
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  writeFileSync(tmp, content);
  renameSync(tmp, path);
}

function loadState(path: string): DistillState {
  try {
    const s = JSON.parse(readFileSync(path, "utf8")) as Partial<DistillState>;
    return {
      lastLineCount: s.lastLineCount ?? 0,
      lastTranscriptSize: s.lastTranscriptSize ?? 0,
      lastRunMs: s.lastRunMs ?? 0,
      distilled: Array.isArray(s.distilled) ? s.distilled : [],
    };
  } catch {
    return {
      lastLineCount: 0,
      lastTranscriptSize: 0,
      lastRunMs: 0,
      distilled: [],
    };
  }
}

/** Non-empty transcript lines — the single split used by both distill and the flush gate. */
function transcriptLines(content: string): string[] {
  return content.split("\n").filter((l) => l.length > 0);
}

function loadBuffer(projDir: string): FileBuffer {
  const path = join(projDir, "buffer.json");
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return { now: [], recent: [] }; // absent: a fresh buffer
  }
  try {
    const b = JSON.parse(raw) as Partial<FileBuffer>;
    return { now: b.now ?? [], recent: b.recent ?? [] };
  } catch {
    // Corrupt (e.g. an interrupted concurrent write). Preserve the bytes for
    // recovery rather than silently wiping the warm buffer, then start fresh.
    try {
      renameSync(path, `${path}.corrupt`);
    } catch {
      // ignore: best-effort preservation
    }
    process.stderr.write(
      `[kiro-memory] corrupt buffer preserved: ${path}.corrupt\n`,
    );
    return { now: [], recent: [] };
  }
}

function renderTier(blocks: string[]): string {
  return blocks.length ? `${blocks.join("\n\n")}\n` : "";
}

/**
 * One distiller run (a background Stop-hook invocation). Debounce-gate, extract the
 * undistilled complete turns, roll them into the tiered file buffer, hand raw turn
 * text to the backend (best-effort), and persist per-session state. Synchronous fs
 * (a one-shot background process); the file buffer write is unconditional so memory
 * survives the backend being down. State is persisted BEFORE the backend call so a
 * hung/slow backend cannot cause the same turns to be re-distilled and duplicated.
 */
export function distill(cfg: DistillConfig): DistillResult {
  const projectId = deriveProjectId(cfg.gitCommonDir, cfg.cwd);
  const projDir = join(cfg.memoryDir, projectId);

  const transcriptPath = locateTranscript(cfg.sessionsDir, cfg.sessionId);
  if (!transcriptPath)
    return { projectId, distilled: 0, skipped: "no-transcript" };

  let content: string;
  try {
    content = readFileSync(transcriptPath, "utf8");
  } catch {
    // Raced with a rotation/removal after locateTranscript's existsSync check.
    return { projectId, distilled: 0, skipped: "no-transcript" };
  }
  const lines = transcriptLines(content);
  const lineCount = lines.length;
  const transcriptSize = Buffer.byteLength(content, "utf8");

  const statePath = join(projDir, ".state", `${cfg.sessionId}.json`);
  const state = loadState(statePath);

  if (
    !cfg.force &&
    !shouldDistill(state, { lineCount, nowMs: cfg.nowMs }, cfg.debounce)
  ) {
    return { projectId, distilled: 0, skipped: "debounced" };
  }

  const turns = selectUndistilledTurns(lines, new Set(state.distilled));
  if (turns.length === 0) {
    // No complete turn to distill, but the transcript may have GROWN (an in-flight or
    // aborted tail, or a legacy pre-D24 state with lastTranscriptSize=0). Advance ONLY
    // the flush stat-watermark — NOT the debounce baselines (lastLineCount/lastRunMs) —
    // so flushSessionTails' size gate stops re-reading + re-parsing this session on
    // every SessionStart. Guarded on growth so a genuine no-op writes nothing.
    if (transcriptSize > state.lastTranscriptSize) {
      writeAtomic(
        statePath,
        JSON.stringify({
          lastLineCount: state.lastLineCount,
          lastTranscriptSize: transcriptSize,
          lastRunMs: state.lastRunMs,
          distilled: state.distilled,
        }),
      );
    }
    return { projectId, distilled: 0, skipped: "no-new-turns" };
  }

  // File buffer (unconditional — this tier must survive the backend being down).
  const blocks = turns.map((t) => formatTurnBlock(t, cfg.format));
  const buf = loadBuffer(projDir);
  const rolled = rollTiers(
    { now: buf.now, recent: buf.recent, archive: [] },
    blocks,
    cfg.roll,
  );
  writeAtomic(
    join(projDir, "buffer.json"),
    JSON.stringify({ now: rolled.now, recent: rolled.recent }),
  );
  writeAtomic(join(projDir, "now.md"), renderTier(rolled.now));
  writeAtomic(join(projDir, "recent.md"), renderTier(rolled.recent));
  if (rolled.archive.length) {
    mkdirSync(projDir, { recursive: true });
    appendFileSync(
      join(projDir, "archive.md"),
      `${rolled.archive.join("\n\n")}\n`,
    );
  }

  // Persist state BEFORE the backend call: the turns are now durably in the file
  // buffer, so marking them distilled here prevents a slow/killed backend from
  // causing them to be re-distilled and re-appended on the next run.
  writeAtomic(
    statePath,
    JSON.stringify({
      lastLineCount: lineCount,
      lastTranscriptSize: transcriptSize,
      lastRunMs: cfg.nowMs,
      distilled: [...state.distilled, ...turns.map((t) => t.execId)],
    }),
  );

  // Memory backend (best-effort — a failure must not lose the file buffer).
  if (cfg.backendWrite) {
    for (const t of turns) {
      try {
        cfg.backendWrite({ projectId, content: turnToMemoryText(t), turn: t });
      } catch {
        // openmemory helper missing / daemon down — the turn is already in the buffer.
      }
    }
  }

  return { projectId, distilled: turns.length, skipped: null };
}

// --- cross-session tail-flush (SessionStart hook) ---

export interface FlushConfig {
  /** the just-started session, EXCLUDED from the flush (it has nothing to flush). */
  currentSessionId: string;
  cwd: string;
  gitCommonDir: string | null;
  sessionsDir: string;
  memoryDir: string;
  nowMs: number;
  roll: RollOpts;
  format: FormatOpts;
  backendWrite?: BackendWrite;
}

export interface FlushResult {
  projectId: string;
  /** the prior sessions that had an unflushed tail, and how many turns each yielded. */
  flushed: Array<{ sessionId: string; distilled: number }>;
}

/**
 * Flush the tails the per-turn debounce dropped. v3 has no SessionEnd hook, so a
 * session whose final turn(s) stayed under the debounce threshold never gets a last
 * distill (D24). On SessionStart, scan the project's prior sessions and force-distill
 * any whose transcript GREW past its last recorded byte size — using a stat-only size
 * gate so a caught-up session costs a locate + stat, never a read/parse. distill() is
 * idempotent (execId dedup), so a spurious flush is a harmless no-op. A grown session
 * that yields no NEW complete turn still advances its watermark (distill no-new-turns
 * path), so an aborted/in-flight tail or a legacy pre-D24 state is stat-skipped after
 * one flush rather than re-parsed on every SessionStart.
 *
 * Bounded-in-practice, not bounded-in-theory: the scan is O(prior sessions in the
 * project), and .state entries accrue over a repo's lifetime with no pruning yet
 * (a later hardening item). The expensive read+parse is gated to grown sessions only.
 */
export function flushSessionTails(cfg: FlushConfig): FlushResult {
  const projectId = deriveProjectId(cfg.gitCommonDir, cfg.cwd);
  const stateDir = join(cfg.memoryDir, projectId, ".state");
  const flushed: FlushResult["flushed"] = [];

  let entries: string[];
  try {
    entries = readdirSync(stateDir);
  } catch {
    return { projectId, flushed }; // project has never distilled: no .state dir
  }

  for (const entry of entries) {
    if (!entry.endsWith(".json")) continue;
    const sessionId = entry.slice(0, -".json".length);
    if (sessionId === cfg.currentSessionId) continue; // never flush the live session
    if (!isValidSessionId(sessionId)) continue; // defense-in-depth on the path key

    const transcriptPath = locateTranscript(cfg.sessionsDir, sessionId);
    if (!transcriptPath) continue; // transcript gone (rotated/removed)
    let size: number;
    try {
      size = statSync(transcriptPath).size;
    } catch {
      continue; // vanished between locate and stat
    }
    const state = loadState(join(stateDir, entry));
    if (size <= state.lastTranscriptSize) continue; // caught up — no unflushed tail

    const res = distill({
      sessionId,
      cwd: cfg.cwd,
      gitCommonDir: cfg.gitCommonDir,
      sessionsDir: cfg.sessionsDir,
      memoryDir: cfg.memoryDir,
      nowMs: cfg.nowMs,
      force: true, // bypass the debounce — flushing the tail is the whole point
      debounce: { minNewLines: 0, cooldownMs: 0 },
      roll: cfg.roll,
      format: cfg.format,
      backendWrite: cfg.backendWrite,
    });
    if (res.distilled > 0)
      flushed.push({ sessionId, distilled: res.distilled });
  }

  return { projectId, flushed };
}

// --- CLI entry (the Stop / Manual hook invokes this in the background) ---

function defaultBackendWrite(fact: {
  projectId: string;
  content: string;
}): void {
  // Hand raw turn text to the openmemory SDK helper if present; the helper scopes
  // the write by project_id (D20). Best-effort: absence/failure is swallowed.
  try {
    execFileSync("openmemory-mem", ["add", "--project-id", fact.projectId], {
      input: fact.content,
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 5_000,
      killSignal: "SIGKILL",
    });
  } catch {
    // helper not installed / daemon down.
  }
}

async function readStdin(): Promise<string> {
  const chunks: Uint8Array[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Uint8Array);
  return Buffer.concat(chunks).toString("utf8");
}

function envNum(name: string, fallback: number): number {
  const raw = process.env[name];
  const n = raw === undefined ? Number.NaN : Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

/**
 * session_id comes from the hook stdin (semi-trusted) and is interpolated into
 * filesystem paths, so constrain it to kiro's actual id shape and reject "."/".."/
 * separators before any path use (defense-in-depth against traversal).
 */
export function isValidSessionId(s: string): boolean {
  return /^[A-Za-z0-9._-]{1,128}$/.test(s) && s !== "." && s !== "..";
}

interface CliEnv {
  sessionsDir: string;
  memoryDir: string;
  roll: RollOpts;
  format: FormatOpts;
}

/** Shared env-derived config for both hook entry points (DRY). */
function resolveCliEnv(home: string): CliEnv {
  return {
    sessionsDir:
      process.env.KIRO_MEMORY_SESSIONS_DIR ?? join(home, ".kiro", "sessions"),
    memoryDir: process.env.KIRO_MEMORY_DIR ?? join(home, ".kiro-memory"),
    roll: {
      maxNowTurns: envNum("KIRO_MEMORY_MAX_NOW", 6),
      maxRecentTurns: envNum("KIRO_MEMORY_MAX_RECENT", 20),
    },
    format: {},
  };
}

/** Hook stdin is metadata-only (D12): {session_id, cwd}. Tolerate anything else. */
async function readMeta(): Promise<{
  sessionId: string;
  cwd: string;
  home: string;
}> {
  let meta: { session_id?: string; cwd?: string } = {};
  try {
    meta = JSON.parse((await readStdin()) || "{}");
  } catch {
    // not JSON — fall through to defaults
  }
  return {
    sessionId: meta.session_id ?? "",
    cwd: meta.cwd ?? process.cwd(),
    home: process.env.HOME ?? "",
  };
}

/** Stop / Manual hook: distill the current session's newly-completed turns. */
export async function main(): Promise<void> {
  const { sessionId, cwd, home } = await readMeta();
  if (!isValidSessionId(sessionId)) return; // nothing safe to key on
  const env = resolveCliEnv(home);

  try {
    const res = distill({
      sessionId,
      cwd,
      ...env,
      nowMs: Date.now(),
      gitCommonDir: resolveGitCommonDir(cwd),
      force: process.env.KIRO_MEMORY_FORCE === "1",
      debounce: {
        minNewLines: envNum("KIRO_MEMORY_MIN_NEW_LINES", 12),
        cooldownMs: envNum("KIRO_MEMORY_COOLDOWN_MS", 90_000),
      },
      backendWrite: defaultBackendWrite,
    });
    process.stderr.write(`[kiro-memory] ${JSON.stringify(res)}\n`);
  } catch (e) {
    // Never let a background distiller crash noisily via unhandledRejection.
    process.stderr.write(`[kiro-memory] error: ${String(e)}\n`);
  }
}

/**
 * SessionStart hook: flush prior sessions' tails the per-turn debounce dropped (D24).
 * The stdin session_id is the just-started session, used only to exclude it.
 */
export async function mainFlush(): Promise<void> {
  const { sessionId, cwd, home } = await readMeta();
  const env = resolveCliEnv(home);

  try {
    const res = flushSessionTails({
      currentSessionId: sessionId,
      cwd,
      ...env,
      gitCommonDir: resolveGitCommonDir(cwd),
      nowMs: Date.now(),
      backendWrite: defaultBackendWrite,
    });
    process.stderr.write(`[kiro-memory] flush ${JSON.stringify(res)}\n`);
  } catch (e) {
    process.stderr.write(`[kiro-memory] flush error: ${String(e)}\n`);
  }
}

if (import.meta.main) {
  void (process.argv.includes("--flush") ? mainFlush() : main());
}
