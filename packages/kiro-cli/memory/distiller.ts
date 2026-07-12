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
 * Cheap pre-parse debounce gate. Stop fires per-turn (D11), so distill only once
 * enough new lines have accrued AND the cooldown has elapsed. The third "dirty-flag"
 * signal (are there actually undistilled complete turns?) is evaluated after parsing,
 * only once this gate has already passed — see distill().
 */
export function shouldDistill(
  state: Pick<DistillState, "lastLineCount" | "lastRunMs">,
  current: { lineCount: number; nowMs: number },
  opts: DebounceOpts,
): boolean {
  const enoughNew = current.lineCount - state.lastLineCount >= opts.minNewLines;
  const cooledDown = current.nowMs - state.lastRunMs >= opts.cooldownMs;
  return enoughNew && cooledDown;
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
      lastRunMs: s.lastRunMs ?? 0,
      distilled: Array.isArray(s.distilled) ? s.distilled : [],
    };
  } catch {
    return { lastLineCount: 0, lastRunMs: 0, distilled: [] };
  }
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
  const lines = content.split("\n").filter((l) => l.length > 0);
  const lineCount = lines.length;

  const statePath = join(projDir, ".state", `${cfg.sessionId}.json`);
  const state = loadState(statePath);

  if (
    !cfg.force &&
    !shouldDistill(state, { lineCount, nowMs: cfg.nowMs }, cfg.debounce)
  ) {
    return { projectId, distilled: 0, skipped: "debounced" };
  }

  const turns = selectUndistilledTurns(lines, new Set(state.distilled));
  if (turns.length === 0)
    return { projectId, distilled: 0, skipped: "no-new-turns" };

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

export async function main(): Promise<void> {
  let meta: { session_id?: string; cwd?: string } = {};
  try {
    meta = JSON.parse((await readStdin()) || "{}");
  } catch {
    // Stop hook stdin is metadata-only (D12); tolerate anything unexpected.
  }
  const sessionId = meta.session_id ?? "";
  if (!isValidSessionId(sessionId)) return; // nothing safe to key on
  const cwd = meta.cwd ?? process.cwd();
  const home = process.env.HOME ?? "";

  try {
    const res = distill({
      sessionId,
      cwd,
      sessionsDir:
        process.env.KIRO_MEMORY_SESSIONS_DIR ?? join(home, ".kiro", "sessions"),
      memoryDir: process.env.KIRO_MEMORY_DIR ?? join(home, ".kiro-memory"),
      nowMs: Date.now(),
      gitCommonDir: resolveGitCommonDir(cwd),
      force: process.env.KIRO_MEMORY_FORCE === "1",
      debounce: {
        minNewLines: envNum("KIRO_MEMORY_MIN_NEW_LINES", 12),
        cooldownMs: envNum("KIRO_MEMORY_COOLDOWN_MS", 90_000),
      },
      roll: {
        maxNowTurns: envNum("KIRO_MEMORY_MAX_NOW", 6),
        maxRecentTurns: envNum("KIRO_MEMORY_MAX_RECENT", 20),
      },
      format: {},
      backendWrite: defaultBackendWrite,
    });
    process.stderr.write(`[kiro-memory] ${JSON.stringify(res)}\n`);
  } catch (e) {
    // Never let a background distiller crash noisily via unhandledRejection.
    process.stderr.write(`[kiro-memory] error: ${String(e)}\n`);
  }
}

if (import.meta.main) void main();
