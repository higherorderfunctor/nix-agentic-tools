// openmemory-mem — SDK helper binary for the auto-memory backend (D19/D20).
//
// The deterministic memory-backend seam the kiro-cli distiller shells out to
// (`openmemory-mem add --project-id <id>`, content on stdin) and the read side
// queries (`openmemory-mem query --project-id <id> [--limit n]`, query on stdin).
// It wraps openmemory-js's in-process `Memory` SDK, which writes/reads Postgres
// DIRECTLY — bypassing the HTTP `serve` daemon's tenant layer, so no auth/tenant
// applies (D20; the model uses the daemon, the hooks use this). Isolation is the
// worktree-shared `project_id` (D19); a project query also returns `system_global`.
//
// The SDK is an INJECTED seam (`MemoryBackend`), so the pure CLI core is unit-
// testable with a stub — no live daemon/Postgres needed. The real backend is
// built LAZILY in the entry (a dynamic import of the co-packaged `./dist/index.js`
// that connects to Postgres on load), so the test process never touches it. This
// mirrors the distiller's `backendWrite` injection.

/** A single search result, normalized from openmemory's `hsg_query` row shape. */
export interface Hit {
  id: string;
  score: number;
  sector: string;
  salience: number;
  content: string;
}

/** The injected backend seam — the subset of the `Memory` SDK this helper uses. */
export interface MemoryBackend {
  add(content: string, opts: { projectId: string }): Promise<void>;
  search(
    query: string,
    opts: { projectId: string; limit: number },
  ): Promise<Hit[]>;
}

export interface MemArgs {
  cmd: "add" | "query";
  projectId: string;
  /** result cap for `query` (ignored by `add`). */
  limit: number;
}

/**
 * Injected I/O sinks. `err` is injected (not a bare `process.stderr.write`) so
 * error-path tests capture and assert the diagnostic instead of leaking it to the
 * runner's stderr — clean output, stronger tests.
 */
export interface MemIO {
  readStdin: () => Promise<string>;
  out: (s: string) => void;
  err: (s: string) => void;
}

const DEFAULT_LIMIT = 5;

/**
 * Parse `add|query --project-id <id> [--limit <n>]`. Flags are order-independent
 * and may precede the subcommand. project_id is mandatory and non-empty (the
 * whole point is project-scoped memory); an invalid/<1 limit is a hard error
 * rather than a silent fallback so a typo'd flag is loud.
 */
export function parseArgs(argv: string[]): MemArgs | { error: string } {
  let cmd: string | null = null;
  let projectId: string | null = null;
  let limit = DEFAULT_LIMIT;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--project-id") {
      // Reject a flag-shaped value (loud, per the docstring) rather than silently
      // capturing e.g. "--limit" as the id when the id was omitted.
      const v = argv[i + 1];
      if (v === undefined || v.startsWith("-")) {
        return { error: "--project-id needs a value" };
      }
      projectId = argv[++i];
    } else if (a === "--limit") {
      if (i + 1 >= argv.length) return { error: "--limit needs a value" };
      const raw = argv[++i];
      const n = Number(raw);
      if (!Number.isInteger(n) || n < 1) {
        return { error: `--limit must be an integer >= 1, got ${raw}` };
      }
      limit = n;
    } else if (a.startsWith("-")) {
      return { error: `unknown flag: ${a}` };
    } else if (cmd === null) {
      cmd = a;
    } else {
      return { error: `unexpected argument: ${a}` };
    }
  }

  if (cmd !== "add" && cmd !== "query") {
    return { error: `expected subcommand add|query, got ${cmd ?? "(none)"}` };
  }
  if (projectId === null || projectId === "") {
    return { error: "--project-id is required and must be non-empty" };
  }
  return { cmd, projectId, limit };
}

// Codepoint-aware so truncation never splits a surrogate pair on astral content;
// mirrors openmemory's codepoint-based fmt_matches (a UTF-16 slice could emit a
// lone surrogate that renders as U+FFFD).
const trunc = (s: string, max = 200) => {
  const cps = Array.from(s);
  return cps.length <= max ? s : `${cps.slice(0, max).join("").trimEnd()}...`;
};

/**
 * Render hits the way openmemory's own MCP `fmt_matches` does, so the injected
 * context reads identically whether it came from the model's tool call or this
 * hook: `N. [sector] score=… salience=… id=…` then a whitespace-collapsed preview.
 */
export function formatHits(hits: Hit[]): string {
  return hits
    .map((h, i) => {
      const preview = trunc(h.content.replace(/\s+/g, " ").trim());
      return `${i + 1}. [${h.sector}] score=${h.score.toFixed(3)} salience=${h.salience.toFixed(3)} id=${h.id}\n${preview}`;
    })
    .join("\n\n");
}

/**
 * Project openmemory hsg_query rows onto our Hit shape — the drift-prone field
 * mapping (`primary_sector` -> sector) plus defensive numeric/string coercion.
 * Exported so an adapter typo or an SDK field rename surfaces as a red unit test
 * rather than a silently-blank read hook. The live rows come from realBackend.
 */
export function normalizeRows(rows: Array<Record<string, unknown>>): Hit[] {
  return rows.map((m) => ({
    id: String(m.id ?? ""),
    score: Number(m.score ?? 0),
    sector: String(m.primary_sector ?? ""),
    salience: Number(m.salience ?? 0),
    content: String(m.content ?? ""),
  }));
}

/**
 * The pure CLI core. Returns a process exit code: 0 ok, 1 backend/operation
 * failure (best-effort — the distiller swallows it), 2 usage error. `makeBackend`
 * is a lazy factory so an empty-stdin no-op or a usage error never constructs the
 * real backend (and so never connects to Postgres). Backend errors are caught, not
 * thrown, so a down daemon can never crash the caller with an unhandled rejection.
 */
export async function runMem(
  argv: string[],
  io: MemIO,
  makeBackend: () => Promise<MemoryBackend>,
): Promise<number> {
  const parsed = parseArgs(argv);
  if ("error" in parsed) {
    io.err(`openmemory-mem: ${parsed.error}\n`);
    return 2;
  }

  const input = (await io.readStdin()).trim();
  if (!input) return 0; // nothing to store/search: never build the backend

  let backend: MemoryBackend;
  try {
    backend = await makeBackend();
  } catch (e) {
    io.err(`openmemory-mem: backend unavailable: ${String(e)}\n`);
    return 1;
  }

  try {
    if (parsed.cmd === "add") {
      await backend.add(input, { projectId: parsed.projectId });
      return 0;
    }
    const hits = await backend.search(input, {
      projectId: parsed.projectId,
      limit: parsed.limit,
    });
    if (hits.length) io.out(formatHits(hits));
    return 0;
  } catch (e) {
    io.err(`openmemory-mem: ${parsed.cmd} failed: ${String(e)}\n`);
    return 1;
  }
}

/** Read all of stdin as UTF-8 (metadata-free: the raw fact/query text). */
async function readStdin(): Promise<string> {
  const chunks: Uint8Array[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Uint8Array);
  return Buffer.concat(chunks).toString("utf8");
}

/**
 * Build the real backend by lazily importing the co-packaged openmemory-js barrel
 * (`./dist/index.js`, resolved relative to this file in the built store output).
 * `new Memory(user_id?)` reads OM_* env at import to reach the SAME Postgres the
 * daemon uses. The SDK path carries no tenant, so writes default to user_id
 * "anonymous"; `OM_USER_ID` overrides it to align with the daemon's tenant
 * (e.g. `dev-no-auth`) at the consumer flip (Q10). search() has no user filter
 * when unset, so the hook read/write loop is self-consistent regardless.
 */
/** The subset of the openmemory-js `Memory` instance the helper drives (D20). */
interface OpenmemoryInstance {
  add(content: string, opts?: Record<string, unknown>): Promise<unknown>;
  search(
    query: string,
    opts?: Record<string, unknown>,
  ): Promise<Array<Record<string, unknown>>>;
}

async function realBackend(): Promise<MemoryBackend> {
  const barrel = new URL("./dist/index.js", import.meta.url).href;
  const { Memory } = (await import(barrel)) as {
    Memory: new (userId?: string) => OpenmemoryInstance;
  };
  const mem = new Memory(process.env.OM_USER_ID || undefined);
  return {
    async add(content, { projectId }) {
      await mem.add(content, { project_id: projectId });
    },
    async search(query, { projectId, limit }) {
      const rows = await mem.search(query, { project_id: projectId, limit });
      return normalizeRows(rows);
    },
  };
}

if (import.meta.main) {
  const io: MemIO = {
    readStdin,
    out: (s) => process.stdout.write(s),
    err: (s) => process.stderr.write(s),
  };
  runMem(process.argv.slice(2), io, realBackend).then(
    (code) => process.exit(code),
    (e) => {
      process.stderr.write(`openmemory-mem: fatal: ${String(e)}\n`);
      process.exit(1);
    },
  );
}
