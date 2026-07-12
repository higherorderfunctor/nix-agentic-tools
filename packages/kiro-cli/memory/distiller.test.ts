import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  type BackendWrite,
  type DistillConfig,
  deriveProjectId,
  distill,
  formatTurnBlock,
  isValidSessionId,
  locateTranscript,
  parseTranscript,
  resolveGitCommonDir,
  rollTiers,
  selectUndistilledTurns,
  shouldDistill,
  type Turn,
  turnToMemoryText,
} from "./distiller.ts";

// --- schema-accurate synthetic record builders (kiro-cli 2.11.1) ---
// Each transcript line is {id, payload, timestamp}; discriminator is payload.type.
let seq = 0;
const line = (
  payload: unknown,
  ts = `2026-07-11T00:00:${String(seq).padStart(2, "0")}Z`,
) => JSON.stringify({ id: `id-${seq++}`, payload, timestamp: ts });

const userMsg = (content: string) =>
  line({ type: "user", content, documents: [], images: [] });
const turnStart = (executionId: string) =>
  line({ type: "turn_start", executionId });
const assistant = (
  executionId: string,
  operationType: "Say" | "Reasoning",
  content: string,
) => line({ type: "assistant", executionId, operationType, content });
const turnEnd = (executionId: string, stopReason = "end_turn") =>
  line({ type: "turn_end", executionId, stopReason });
const usageSummary = (executionId: string, usedTools: string[]) =>
  line({
    type: "usage_summary",
    executionId,
    status: "success",
    elapsedTime: 1000,
    promptTurnSummaries: [
      { unit: "credit", unitPlural: "credits", usage: 1.5, usedTools },
    ],
  });

describe("parseTranscript", () => {
  test("extracts one complete turn: user prompt + concatenated Say content", () => {
    const lines = [
      userMsg("how do I add a nix package?"),
      turnStart("exec-1"),
      assistant(
        "exec-1",
        "Reasoning",
        "internal chain of thought, should be dropped",
      ),
      assistant("exec-1", "Say", "Add it to the overlay."),
      assistant("exec-1", "Say", "Then run nix build."),
      usageSummary("exec-1", ["read_file", "grep_search"]),
      turnEnd("exec-1"),
    ];

    const turns: Turn[] = parseTranscript(lines);

    expect(turns).toHaveLength(1);
    const t = turns[0]!;
    expect(t.execId).toBe("exec-1");
    expect(t.userPrompt).toBe("how do I add a nix package?");
    expect(t.assistantSay).toBe(
      "Add it to the overlay.\n\nThen run nix build.",
    );
    expect(t.assistantSay).not.toContain("internal chain of thought");
    expect(t.usedTools).toEqual(["read_file", "grep_search"]);
    expect(t.complete).toBe(true);
  });

  test("separates multiple turns and associates each user prompt correctly", () => {
    const lines = [
      userMsg("first ask"),
      turnStart("e1"),
      assistant("e1", "Say", "first answer"),
      turnEnd("e1"),
      userMsg("second ask"),
      turnStart("e2"),
      assistant("e2", "Say", "second answer"),
      turnEnd("e2"),
    ];

    const turns = parseTranscript(lines);

    expect(turns.map((t) => t.execId)).toEqual(["e1", "e2"]);
    expect(turns.map((t) => t.userPrompt)).toEqual(["first ask", "second ask"]);
    expect(turns.map((t) => t.assistantSay)).toEqual([
      "first answer",
      "second answer",
    ]);
  });

  test("marks an in-flight turn (no turn_end) as incomplete but still returns it", () => {
    const lines = [
      userMsg("ask"),
      turnStart("e1"),
      assistant("e1", "Say", "partial answer"),
    ];

    const turns = parseTranscript(lines);

    expect(turns).toHaveLength(1);
    expect(turns[0]!.complete).toBe(false);
    expect(turns[0]!.assistantSay).toBe("partial answer");
  });

  test("skips blank and malformed lines without throwing", () => {
    const lines = [
      "",
      "   ",
      "{ not json",
      JSON.stringify({ no: "payload" }),
      userMsg("ask"),
      turnStart("e1"),
      assistant("e1", "Say", "answer"),
      turnEnd("e1"),
    ];

    const turns = parseTranscript(lines);

    expect(turns).toHaveLength(1);
    expect(turns[0]!.userPrompt).toBe("ask");
  });

  test("a turn with no preceding user message has userPrompt=null", () => {
    const lines = [
      turnStart("e1"),
      assistant("e1", "Say", "answer"),
      turnEnd("e1"),
    ];

    const turns = parseTranscript(lines);

    expect(turns).toHaveLength(1);
    expect(turns[0]!.userPrompt).toBeNull();
  });

  test("a Reasoning-only turn yields an empty assistantSay", () => {
    const lines = [
      userMsg("ask"),
      turnStart("e1"),
      assistant("e1", "Reasoning", "just thinking"),
      turnEnd("e1"),
    ];

    const turns = parseTranscript(lines);

    expect(turns[0]!.assistantSay).toBe("");
  });
});

describe("selectUndistilledTurns", () => {
  const threeTurns = [
    userMsg("ask 1"),
    turnStart("e1"),
    assistant("e1", "Say", "a1"),
    turnEnd("e1"),
    userMsg("ask 2"),
    turnStart("e2"),
    assistant("e2", "Say", "a2"),
    turnEnd("e2"),
    userMsg("ask 3"),
    turnStart("e3"),
    assistant("e3", "Say", "a3"), // in-flight: no turn_end
  ];

  test("returns all complete, not-yet-distilled turns and excludes the in-flight one", () => {
    const turns = selectUndistilledTurns(threeTurns, new Set());
    expect(turns.map((t) => t.execId)).toEqual(["e1", "e2"]);
  });

  test("excludes turns whose execId is already distilled", () => {
    const turns = selectUndistilledTurns(threeTurns, new Set(["e1"]));
    expect(turns.map((t) => t.execId)).toEqual(["e2"]);
  });

  test("returns nothing when every complete turn is already distilled", () => {
    const turns = selectUndistilledTurns(threeTurns, new Set(["e1", "e2"]));
    expect(turns).toEqual([]);
  });
});

describe("deriveProjectId", () => {
  test("slug is <sanitized-basename>-<hash> from the repo root (parent of .git)", () => {
    const id = deriveProjectId(
      "/home/u/projects/sample/.git",
      "/home/u/projects/sample/sub/dir",
    );
    expect(id).toMatch(/^sample-[0-9a-f]{8}$/);
  });

  test("all worktrees of a repo share one project_id (common-dir is the main .git)", () => {
    // Two different working dirs (main checkout + a linked worktree), SAME common-dir.
    const mainGit = "/home/u/projects/sample/.git";
    const fromMain = deriveProjectId(mainGit, "/home/u/projects/sample");
    const fromWorktree = deriveProjectId(
      mainGit,
      "/home/u/worktrees/sample-feature",
    );
    expect(fromWorktree).toBe(fromMain);
  });

  test("same basename under different parents does NOT collide (hash differs)", () => {
    const a = deriveProjectId("/a/sample/.git", "/a/sample");
    const b = deriveProjectId("/b/sample/.git", "/b/sample");
    expect(a).not.toBe(b);
    expect(a.startsWith("sample-")).toBe(true);
    expect(b.startsWith("sample-")).toBe(true);
  });

  test("non-git cwd (null common-dir) falls back to a slug of the cwd", () => {
    const id = deriveProjectId(null, "/tmp/scratch/not a git repo");
    expect(id).toMatch(/^not-a-git-repo-[0-9a-f]{8}$/);
  });

  test("is deterministic for the same inputs", () => {
    const a = deriveProjectId("/x/repo/.git", "/x/repo");
    const b = deriveProjectId("/x/repo/.git", "/x/repo");
    expect(a).toBe(b);
  });
});

describe("shouldDistill (debounce gate)", () => {
  const opts = { minNewLines: 10, cooldownMs: 60_000 };

  test("true when enough new lines AND cooldown elapsed", () => {
    const ok = shouldDistill(
      { lastLineCount: 100, lastRunMs: 0 },
      { lineCount: 115, nowMs: 60_000 },
      opts,
    );
    expect(ok).toBe(true);
  });

  test("false when too few new lines, even past cooldown", () => {
    const ok = shouldDistill(
      { lastLineCount: 100, lastRunMs: 0 },
      { lineCount: 105, nowMs: 10_000_000 },
      opts,
    );
    expect(ok).toBe(false);
  });

  test("false when cooldown not elapsed, even with many new lines", () => {
    const ok = shouldDistill(
      { lastLineCount: 0, lastRunMs: 50_000 },
      { lineCount: 500, nowMs: 90_000 }, // only 40s since last run
      opts,
    );
    expect(ok).toBe(false);
  });

  test("first run (zeroed state) distills once there is enough content", () => {
    const ok = shouldDistill(
      { lastLineCount: 0, lastRunMs: 0 },
      { lineCount: 12, nowMs: 60_000 },
      opts,
    );
    expect(ok).toBe(true);
  });

  test("boundaries are inclusive (delta == min, gap == cooldown)", () => {
    const ok = shouldDistill(
      { lastLineCount: 100, lastRunMs: 0 },
      { lineCount: 110, nowMs: 60_000 },
      opts,
    );
    expect(ok).toBe(true);
  });
});

const makeTurn = (over: Partial<Turn> = {}): Turn => ({
  execId: "e1",
  userPrompt: "how do I add a nix package?",
  assistantSay: "Add it to the overlay, then run nix build.",
  usedTools: ["read_file", "grep_search"],
  startTs: "2026-07-11T00:00:01Z",
  endTs: "2026-07-11T00:00:06Z",
  complete: true,
  ...over,
});

describe("formatTurnBlock", () => {
  test("renders ask, answer, and tools with a timestamp heading", () => {
    const block = formatTurnBlock(makeTurn());
    expect(block).toContain("2026-07-11T00:00:06Z");
    expect(block).toContain("how do I add a nix package?");
    expect(block).toContain("Add it to the overlay, then run nix build.");
    expect(block).toContain("read_file");
    expect(block).toContain("grep_search");
  });

  test("truncates a long answer with an ellipsis at maxSayChars", () => {
    const block = formatTurnBlock(
      makeTurn({ assistantSay: "x".repeat(1000) }),
      {
        maxSayChars: 100,
      },
    );
    expect(block).toContain("…");
    expect(block).not.toContain("x".repeat(101));
    expect(block).toContain("x".repeat(100));
  });

  test("truncates a long prompt at maxPromptChars", () => {
    const block = formatTurnBlock(makeTurn({ userPrompt: "y".repeat(1000) }), {
      maxPromptChars: 50,
    });
    expect(block).toContain("y".repeat(50));
    expect(block).not.toContain("y".repeat(51));
  });

  test("omits the Ask line when there is no user prompt", () => {
    const block = formatTurnBlock(makeTurn({ userPrompt: null }));
    expect(block).not.toContain("Ask:");
  });

  test("omits the tools line when no tools were used", () => {
    const block = formatTurnBlock(makeTurn({ usedTools: [] }));
    expect(block.toLowerCase()).not.toContain("tools:");
  });
});

describe("rollTiers", () => {
  const empty = (): { now: string[]; recent: string[]; archive: string[] } => ({
    now: [],
    recent: [],
    archive: [],
  });
  const opts = { maxNowTurns: 3, maxRecentTurns: 2 };

  test("under capacity: new blocks append to now, other tiers untouched", () => {
    const out = rollTiers(empty(), ["a", "b"], opts);
    expect(out.now).toEqual(["a", "b"]);
    expect(out.recent).toEqual([]);
    expect(out.archive).toEqual([]);
  });

  test("now overflow spills the oldest blocks into recent, newest stay in now", () => {
    const out = rollTiers(
      { now: ["a", "b", "c"], recent: [], archive: [] },
      ["d", "e"],
      opts,
    );
    // now had 3, +2 = 5, keep newest 3 -> [c,d,e]; oldest 2 -> recent
    expect(out.now).toEqual(["c", "d", "e"]);
    expect(out.recent).toEqual(["a", "b"]);
    expect(out.archive).toEqual([]);
  });

  test("recent overflow cascades oldest blocks into the append-only archive", () => {
    const out = rollTiers(
      { now: ["a", "b", "c"], recent: ["r1", "r2"], archive: ["old"] },
      ["d", "e", "f"],
      opts,
    );
    // now: [a,b,c]+[d,e,f]=6, keep newest 3 -> [d,e,f]; spill [a,b,c] to recent
    // recent: [r1,r2]+[a,b,c]=5, keep newest 2 -> [b,c]; spill [r1,r2,a] to archive
    expect(out.now).toEqual(["d", "e", "f"]);
    expect(out.recent).toEqual(["b", "c"]);
    expect(out.archive).toEqual(["old", "r1", "r2", "a"]);
  });

  test("does not mutate the input tiers", () => {
    const input = {
      now: ["a", "b", "c"],
      recent: [] as string[],
      archive: [] as string[],
    };
    rollTiers(input, ["d"], opts);
    expect(input.now).toEqual(["a", "b", "c"]);
  });
});

describe("turnToMemoryText", () => {
  test("includes the full (untruncated) ask and answer", () => {
    const t = makeTurn({
      userPrompt: "the ask",
      assistantSay: "z".repeat(2000),
    });
    const text = turnToMemoryText(t);
    expect(text).toContain("Ask: the ask");
    expect(text).toContain("z".repeat(2000));
  });

  test("omits the Ask prefix when there is no prompt", () => {
    const text = turnToMemoryText(
      makeTurn({ userPrompt: null, assistantSay: "answer only" }),
    );
    expect(text).toBe("answer only");
  });
});

describe("locateTranscript", () => {
  test("finds messages.jsonl under an unknown workspace-hash dir by session_id", () => {
    const root = mkdtempSync(join(tmpdir(), "sess-"));
    const dir = join(root, "9b3c512f46fef95d", "sess_abc");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "messages.jsonl"), "");
    expect(locateTranscript(root, "sess_abc")).toBe(
      join(dir, "messages.jsonl"),
    );
  });

  test("returns null when no session dir matches", () => {
    const root = mkdtempSync(join(tmpdir(), "sess-"));
    expect(locateTranscript(root, "sess_missing")).toBeNull();
  });

  test("returns null when the sessions dir does not exist", () => {
    expect(
      locateTranscript(join(tmpdir(), "definitely-not-here-xyz"), "sess_x"),
    ).toBeNull();
  });
});

describe("resolveGitCommonDir (real git)", () => {
  test("returns the main .git for the repo and shares it across worktrees (D19)", () => {
    const root = mkdtempSync(join(tmpdir(), "distiller-git-"));
    const main = join(root, "main");
    mkdirSync(main);
    execFileSync("git", ["init", "-q", "-b", "trunk", main]);
    execFileSync("git", ["-C", main, "config", "user.email", "t@t"]);
    execFileSync("git", ["-C", main, "config", "user.name", "t"]);
    execFileSync("git", [
      "-C",
      main,
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "init",
    ]);

    const fromMain = resolveGitCommonDir(main);
    expect(fromMain).not.toBeNull();
    expect(fromMain!.endsWith("/.git")).toBe(true);

    const wt = join(root, "wt");
    execFileSync("git", ["-C", main, "worktree", "add", "-q", wt]);
    const fromWt = resolveGitCommonDir(wt);
    // Both the main checkout and its linked worktree resolve to the SAME common dir,
    // so deriveProjectId yields one shared project_id.
    expect(fromWt).toBe(fromMain);
  });

  test("returns null outside any git repo", () => {
    const plainDir = mkdtempSync(join(tmpdir(), "distiller-plain-"));
    expect(resolveGitCommonDir(plainDir)).toBeNull();
  });
});

describe("distill (orchestration)", () => {
  const baseCfg = (over: Partial<DistillConfig>): DistillConfig => ({
    sessionId: "sess_test",
    cwd: "/workdir",
    sessionsDir: "",
    memoryDir: "",
    nowMs: 1_000,
    gitCommonDir: "/fake/sample/.git",
    debounce: { minNewLines: 1, cooldownMs: 0 },
    roll: { maxNowTurns: 10, maxRecentTurns: 10 },
    format: {},
    ...over,
  });

  const twoComplete = [
    userMsg("ask one"),
    turnStart("e1"),
    assistant("e1", "Say", "answer one"),
    turnEnd("e1"),
    userMsg("ask two"),
    turnStart("e2"),
    assistant("e2", "Say", "answer two"),
    turnEnd("e2"),
    userMsg("ask three"),
    turnStart("e3"),
    assistant("e3", "Say", "partial"), // in-flight
  ];

  const setup = (over: Partial<DistillConfig> = {}, lines = twoComplete) => {
    const memoryDir = mkdtempSync(join(tmpdir(), "distiller-memory-"));
    const sessionsDir = mkdtempSync(join(tmpdir(), "distiller-sessions-"));
    const sessionId = over.sessionId ?? "sess_test";
    const dir = join(sessionsDir, "hash1", sessionId);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "messages.jsonl"), `${lines.join("\n")}\n`);
    const calls: Array<{ projectId: string; content: string }> = [];
    const backendWrite: BackendWrite = (f) =>
      calls.push({ projectId: f.projectId, content: f.content });
    const cfg = baseCfg({ memoryDir, sessionsDir, backendWrite, ...over });
    const projectId = deriveProjectId(cfg.gitCommonDir, cfg.cwd);
    return { cfg, memoryDir, projectId, calls };
  };

  test("distills the complete turns, writes now.md, persists state, calls backend", () => {
    const { cfg, memoryDir, projectId, calls } = setup();
    const res = distill(cfg);

    expect(res.skipped).toBeNull();
    expect(res.distilled).toBe(2);
    expect(res.projectId).toBe(projectId);

    const nowMd = readFileSync(join(memoryDir, projectId, "now.md"), "utf8");
    expect(nowMd).toContain("ask one");
    expect(nowMd).toContain("ask two");
    expect(nowMd).not.toContain("ask three"); // in-flight, not distilled

    const state = JSON.parse(
      readFileSync(
        join(memoryDir, projectId, ".state", "sess_test.json"),
        "utf8",
      ),
    );
    expect(state.distilled).toEqual(["e1", "e2"]);

    expect(calls).toHaveLength(2);
    expect(calls[0]!.projectId).toBe(projectId);
    expect(calls[0]!.content).toContain("ask one");
  });

  test("dedup already-distilled turns and only distills newly-completed ones", () => {
    const { cfg, calls } = setup();
    distill(cfg); // first pass distills e1,e2
    expect(calls).toHaveLength(2);

    // e3 completes and a new complete e4 arrives; re-run (force bypasses debounce).
    const dir = join(cfg.sessionsDir, "hash1", "sess_test");
    const grown = [
      ...twoComplete,
      turnEnd("e3"),
      userMsg("ask four"),
      turnStart("e4"),
      assistant("e4", "Say", "answer four"),
      turnEnd("e4"),
    ];
    writeFileSync(join(dir, "messages.jsonl"), `${grown.join("\n")}\n`);

    const res = distill({ ...cfg, force: true, nowMs: 2_000 });
    expect(res.distilled).toBe(2); // e3 + e4 only
    expect(calls).toHaveLength(4);
    expect(calls[2]!.content).toContain("partial"); // e3
    expect(calls[3]!.content).toContain("ask four"); // e4
  });

  test("debounce gate skips when cooldown has not elapsed", () => {
    const { cfg, memoryDir, projectId, calls } = setup({
      debounce: { minNewLines: 1, cooldownMs: 60_000 },
      nowMs: 1_000, // 1000 - 0 < 60000 -> cooled down false
    });
    const res = distill(cfg);
    expect(res.skipped).toBe("debounced");
    expect(res.distilled).toBe(0);
    expect(calls).toHaveLength(0);
    expect(existsSync(join(memoryDir, projectId, "now.md"))).toBe(false);
  });

  test("force bypasses the debounce gate", () => {
    const { cfg } = setup({
      debounce: { minNewLines: 999, cooldownMs: 60_000 },
      force: true,
    });
    const res = distill(cfg);
    expect(res.distilled).toBe(2);
  });

  test("returns no-transcript when the session file is absent", () => {
    const memoryDir = mkdtempSync(join(tmpdir(), "distiller-memory-"));
    const sessionsDir = mkdtempSync(join(tmpdir(), "distiller-sessions-"));
    const res = distill(
      baseCfg({ memoryDir, sessionsDir, sessionId: "sess_absent" }),
    );
    expect(res.skipped).toBe("no-transcript");
    expect(res.distilled).toBe(0);
  });

  test("file buffer is written even when the backend seam is omitted", () => {
    const { cfg, memoryDir, projectId } = setup({ backendWrite: undefined });
    const res = distill(cfg);
    expect(res.distilled).toBe(2);
    expect(existsSync(join(memoryDir, projectId, "now.md"))).toBe(true);
  });

  test("a backend that throws does not lose the file-buffer write", () => {
    const { cfg, memoryDir, projectId } = setup({
      backendWrite: () => {
        throw new Error("backend down");
      },
    });
    const res = distill(cfg);
    expect(res.distilled).toBe(2);
    expect(existsSync(join(memoryDir, projectId, "now.md"))).toBe(true);
  });
});

describe("main (CLI end-to-end via subprocess)", () => {
  test("reads stdin metadata + env config, resolves real git, writes now.md", () => {
    const root = mkdtempSync(join(tmpdir(), "e2e-"));
    const repo = join(root, "repo");
    mkdirSync(repo);
    execFileSync("git", ["init", "-q", "-b", "trunk", repo]);
    execFileSync("git", ["-C", repo, "config", "user.email", "t@t"]);
    execFileSync("git", ["-C", repo, "config", "user.name", "t"]);
    execFileSync("git", [
      "-C",
      repo,
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "init",
    ]);

    const memoryDir = mkdtempSync(join(tmpdir(), "e2e-mem-"));
    const sessionsDir = mkdtempSync(join(tmpdir(), "e2e-sess-"));
    const sessionId = "sess_e2e";
    const sessionDir = join(sessionsDir, "hash1", sessionId);
    mkdirSync(sessionDir, { recursive: true });
    const lines = [
      userMsg("e2e ask"),
      turnStart("e1"),
      assistant("e1", "Say", "e2e answer"),
      turnEnd("e1"),
    ];
    writeFileSync(join(sessionDir, "messages.jsonl"), `${lines.join("\n")}\n`);

    execFileSync("bun", [join(import.meta.dir, "distiller.ts")], {
      input: JSON.stringify({ session_id: sessionId, cwd: repo }),
      env: {
        ...process.env,
        HOME: root,
        KIRO_MEMORY_DIR: memoryDir,
        KIRO_MEMORY_SESSIONS_DIR: sessionsDir,
        KIRO_MEMORY_FORCE: "1",
      },
      stdio: ["pipe", "ignore", "ignore"],
    });

    const projectId = deriveProjectId(resolveGitCommonDir(repo), repo);
    const nowMd = readFileSync(join(memoryDir, projectId, "now.md"), "utf8");
    expect(nowMd).toContain("e2e ask");
    expect(nowMd).toContain("e2e answer");
  });
});

describe("parseTranscript (review hardening)", () => {
  test("a turn_start without executionId does not leak the pending prompt forward", () => {
    const lines = [
      userMsg("ask A"),
      JSON.stringify({
        id: "x",
        timestamp: "t",
        payload: { type: "turn_start" },
      }),
      turnStart("e2"),
      assistant("e2", "Say", "answer 2"),
      turnEnd("e2"),
    ];
    const turns = parseTranscript(lines);
    expect(turns).toHaveLength(1);
    expect(turns[0]!.execId).toBe("e2");
    expect(turns[0]!.userPrompt).toBeNull(); // "ask A" belonged to the malformed turn, not e2
  });

  test("dedup of usedTools across multiple usage_summary rows for one turn", () => {
    const lines = [
      userMsg("ask"),
      turnStart("e1"),
      assistant("e1", "Say", "a"),
      usageSummary("e1", ["read_file", "grep_search"]),
      usageSummary("e1", ["read_file", "file_search"]),
      turnEnd("e1"),
    ];
    const turns = parseTranscript(lines);
    expect(turns[0]!.usedTools).toEqual([
      "read_file",
      "grep_search",
      "file_search",
    ]);
  });
});

describe("review fixes", () => {
  test("isValidSessionId accepts kiro ids, rejects traversal/empty/oversize", () => {
    expect(isValidSessionId("sess_0e60a63f-d08d-4214-996c-d147258c6aea")).toBe(
      true,
    );
    expect(isValidSessionId("")).toBe(false);
    expect(isValidSessionId("..")).toBe(false);
    expect(isValidSessionId("../../tmp/pwn")).toBe(false);
    expect(isValidSessionId("a/b")).toBe(false);
    expect(isValidSessionId("x".repeat(129))).toBe(false);
  });

  test("distill persists state BEFORE calling the backend (dup-on-crash guard)", () => {
    const memoryDir = mkdtempSync(join(tmpdir(), "distiller-memory-"));
    const sessionsDir = mkdtempSync(join(tmpdir(), "distiller-sessions-"));
    const dir = join(sessionsDir, "hash1", "sess_test");
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "messages.jsonl"),
      `${[userMsg("ask"), turnStart("e1"), assistant("e1", "Say", "a"), turnEnd("e1")].join("\n")}\n`,
    );
    const cfg: DistillConfig = {
      sessionId: "sess_test",
      cwd: "/workdir",
      sessionsDir,
      memoryDir,
      nowMs: 1_000,
      gitCommonDir: "/fake/sample/.git",
      debounce: { minNewLines: 1, cooldownMs: 0 },
      roll: { maxNowTurns: 10, maxRecentTurns: 10 },
      format: {},
    };
    const projectId = deriveProjectId(cfg.gitCommonDir, cfg.cwd);
    const statePath = join(memoryDir, projectId, ".state", "sess_test.json");
    let stateExistedWhenBackendCalled = false;
    cfg.backendWrite = () => {
      stateExistedWhenBackendCalled = existsSync(statePath);
    };
    distill(cfg);
    expect(stateExistedWhenBackendCalled).toBe(true);
  });
});
