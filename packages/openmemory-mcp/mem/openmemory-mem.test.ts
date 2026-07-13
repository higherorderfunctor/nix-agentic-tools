import { describe, expect, test } from "bun:test";
import {
  formatHits,
  type Hit,
  type MemoryBackend,
  normalizeRows,
  parseArgs,
  runMem,
} from "./openmemory-mem.ts";

// A stub Memory backend: records every call and never touches Postgres, so the
// pure CLI core is exercised without a live daemon (the SDK is the injected
// seam, D20). `make()` counts constructions so the "never builds the backend"
// short-circuits are provable.
function makeStub(opts?: {
  hits?: Hit[];
  addThrows?: boolean;
  searchThrows?: boolean;
  buildThrows?: boolean;
}) {
  const calls = {
    add: [] as Array<[string, { projectId: string }]>,
    search: [] as Array<[string, { projectId: string; limit: number }]>,
    built: 0,
  };
  const backend: MemoryBackend = {
    async add(content, o) {
      calls.add.push([content, o]);
      if (opts?.addThrows) throw new Error("pg down");
    },
    async search(query, o) {
      calls.search.push([query, o]);
      if (opts?.searchThrows) throw new Error("pg down");
      return opts?.hits ?? [];
    },
  };
  const make = async () => {
    calls.built++;
    if (opts?.buildThrows) throw new Error("dist missing / pg unreachable");
    return backend;
  };
  return { calls, make };
}

const hit = (over: Partial<Hit> = {}): Hit => ({
  id: "m1",
  score: 0.5,
  sector: "semantic",
  salience: 0.9,
  content: "hello world",
  ...over,
});

// A capturing MemIO: stdin is fixed text; out/err collect into buffers so the
// error-path diagnostics are asserted, never leaked to the test runner's stderr.
const io = (stdin: string) => {
  const outBuf: string[] = [];
  const errBuf: string[] = [];
  return {
    readStdin: async () => stdin,
    out: (s: string) => outBuf.push(s),
    err: (s: string) => errBuf.push(s),
    stdout: () => outBuf.join(""),
    stderr: () => errBuf.join(""),
  };
};

describe("parseArgs", () => {
  test("parses `add --project-id <id>`", () => {
    expect(parseArgs(["add", "--project-id", "proj-x"])).toEqual({
      cmd: "add",
      projectId: "proj-x",
      limit: 5,
    });
  });

  test("parses `query --project-id <id> --limit <n>`", () => {
    expect(
      parseArgs(["query", "--project-id", "proj-x", "--limit", "3"]),
    ).toEqual({ cmd: "query", projectId: "proj-x", limit: 3 });
  });

  test("query defaults limit to 5 when omitted", () => {
    expect(parseArgs(["query", "--project-id", "p"])).toEqual({
      cmd: "query",
      projectId: "p",
      limit: 5,
    });
  });

  test("flags may precede the subcommand (order-independent)", () => {
    expect(parseArgs(["--project-id", "p", "add"])).toEqual({
      cmd: "add",
      projectId: "p",
      limit: 5,
    });
  });

  test("missing subcommand is an error", () => {
    expect(parseArgs(["--project-id", "p"])).toHaveProperty("error");
  });

  test("unknown subcommand is an error", () => {
    expect(parseArgs(["delete", "--project-id", "p"])).toHaveProperty("error");
  });

  test("missing --project-id is an error (project scope is required)", () => {
    expect(parseArgs(["add"])).toHaveProperty("error");
  });

  test("empty --project-id is an error", () => {
    expect(parseArgs(["add", "--project-id", ""])).toHaveProperty("error");
  });

  test("--project-id with no following value is an error", () => {
    expect(parseArgs(["add", "--project-id"])).toHaveProperty("error");
  });

  test("non-integer --limit is an error", () => {
    expect(
      parseArgs(["query", "--project-id", "p", "--limit", "abc"]),
    ).toHaveProperty("error");
  });

  test("--limit below 1 is an error", () => {
    expect(
      parseArgs(["query", "--project-id", "p", "--limit", "0"]),
    ).toHaveProperty("error");
  });

  test("a flag-shaped --project-id value is rejected, not silently consumed", () => {
    // `--project-id --limit` (id omitted): the flag-shaped token must be loud,
    // never captured as projectId="--limit".
    expect(parseArgs(["add", "--project-id", "--limit"])).toHaveProperty(
      "error",
    );
  });

  test("a flag-shaped --limit value is rejected", () => {
    expect(
      parseArgs(["query", "--project-id", "p", "--limit", "--oops"]),
    ).toHaveProperty("error");
  });
});

describe("formatHits", () => {
  test("renders one numbered block per hit, openmemory fmt_matches style", () => {
    const out = formatHits([
      hit({
        id: "a",
        score: 0.4211,
        salience: 0.8,
        sector: "semantic",
        content: "first",
      }),
      hit({
        id: "b",
        score: 0.1,
        salience: 0.25,
        sector: "episodic",
        content: "second",
      }),
    ]);
    expect(out).toBe(
      "1. [semantic] score=0.421 salience=0.800 id=a\nfirst\n\n" +
        "2. [episodic] score=0.100 salience=0.250 id=b\nsecond",
    );
  });

  test("truncates a long preview to 200 chars with an ellipsis", () => {
    const long = "x".repeat(500);
    const out = formatHits([hit({ content: long })]);
    const preview = out.split("\n")[1];
    expect(preview.length).toBe(203); // 200 chars + "..."
    expect(preview.endsWith("...")).toBe(true);
  });

  test("collapses interior whitespace/newlines in the preview", () => {
    const out = formatHits([hit({ content: "a\n\n  b\t c" })]);
    expect(out.split("\n")[1]).toBe("a b c");
  });

  test("truncates astral (multibyte) content without splitting a surrogate pair", () => {
    // Codepoint-aware truncation: a UTF-16 slice at code unit 200 would split the
    // 100th emoji (offset by the leading "a") into a lone high surrogate.
    const out = formatHits([hit({ content: `a${"\u{1F600}".repeat(250)}` })]);
    const preview = out.split("\n")[1];
    // isWellFormed() is false iff a lone (unpaired) surrogate exists — a UTF-16
    // slice mid-emoji leaves one; a codepoint slice never does.
    expect(preview.isWellFormed()).toBe(true);
    expect(preview.endsWith("...")).toBe(true);
  });

  test("trims a boundary space so a whitespace-terminated slice loses the trailing space", () => {
    // slice(0,200) ends on the collapsed space at index 199 -> trimEnd -> 199 + "..."
    const content = `${"w".repeat(199)} ${"z".repeat(50)}`;
    const preview = formatHits([hit({ content })]).split("\n")[1];
    expect(preview).toBe(`${"w".repeat(199)}...`);
    expect(preview.length).toBe(202);
  });

  test("returns an empty string for no hits", () => {
    expect(formatHits([])).toBe("");
  });
});

describe("normalizeRows", () => {
  test("projects a canonical hsg_query row to a Hit (primary_sector -> sector)", () => {
    expect(
      normalizeRows([
        {
          id: "x1",
          score: 0.42,
          primary_sector: "semantic",
          salience: 0.9,
          content: "hi",
          path: "ignored",
        },
      ]),
    ).toEqual([
      {
        id: "x1",
        score: 0.42,
        sector: "semantic",
        salience: 0.9,
        content: "hi",
      },
    ]);
  });

  test("coerces stringy numerics and fills documented defaults for missing fields", () => {
    expect(normalizeRows([{ id: 7, score: "0.5", salience: "0.1" }])).toEqual([
      { id: "7", score: 0.5, sector: "", salience: 0.1, content: "" },
    ]);
    expect(normalizeRows([{}])).toEqual([
      { id: "", score: 0, sector: "", salience: 0, content: "" },
    ]);
  });
});

describe("runMem add", () => {
  test("hands trimmed stdin content to backend.add scoped by project_id", async () => {
    const { calls, make } = makeStub();
    const t = io("  a distilled turn  ");
    const code = await runMem(["add", "--project-id", "p"], t, make);
    expect(code).toBe(0);
    expect(calls.add).toEqual([["a distilled turn", { projectId: "p" }]]);
    expect(t.stdout()).toBe(""); // add writes nothing to stdout
    expect(t.stderr()).toBe(""); // and nothing to stderr on success
  });

  test("empty stdin is a no-op that never builds the backend", async () => {
    const { calls, make } = makeStub();
    const t = io("   \n");
    const code = await runMem(["add", "--project-id", "p"], t, make);
    expect(code).toBe(0);
    expect(calls.built).toBe(0); // smoke-safe: no dist load / pg connect
    expect(calls.add).toEqual([]);
  });

  test("a backend.add failure returns 1 (best-effort; upstream swallows it)", async () => {
    const { make } = makeStub({ addThrows: true });
    const t = io("x");
    const code = await runMem(["add", "--project-id", "p"], t, make);
    expect(code).toBe(1);
    expect(t.stderr()).toContain("add failed");
  });

  test("a backend that fails to construct returns 1 without throwing", async () => {
    const { calls, make } = makeStub({ buildThrows: true });
    const t = io("x");
    const code = await runMem(["add", "--project-id", "p"], t, make);
    expect(code).toBe(1);
    expect(calls.add).toEqual([]);
    expect(t.stderr()).toContain("backend unavailable");
  });
});

describe("runMem query", () => {
  test("searches with the stdin query scoped by project_id + limit, prints formatted hits", async () => {
    const hits = [hit({ id: "h1", content: "match one" })];
    const { calls, make } = makeStub({ hits });
    const t = io("what did we decide");
    const code = await runMem(
      ["query", "--project-id", "p", "--limit", "2"],
      t,
      make,
    );
    expect(code).toBe(0);
    expect(calls.search).toEqual([
      ["what did we decide", { projectId: "p", limit: 2 }],
    ]);
    expect(t.stdout()).toBe(formatHits(hits));
  });

  test("zero hits writes nothing to stdout (inject nothing)", async () => {
    const { make } = makeStub({ hits: [] });
    const t = io("anything");
    const code = await runMem(["query", "--project-id", "p"], t, make);
    expect(code).toBe(0);
    expect(t.stdout()).toBe("");
  });

  test("empty stdin is a no-op that never builds the backend", async () => {
    const { calls, make } = makeStub({ hits: [hit()] });
    const t = io("");
    const code = await runMem(["query", "--project-id", "p"], t, make);
    expect(code).toBe(0);
    expect(calls.built).toBe(0);
    expect(t.stdout()).toBe("");
  });

  test("a backend.search failure returns 1", async () => {
    const { make } = makeStub({ searchThrows: true });
    const t = io("x");
    const code = await runMem(["query", "--project-id", "p"], t, make);
    expect(code).toBe(1);
    expect(t.stderr()).toContain("query failed");
  });
});

describe("runMem usage errors", () => {
  test("invalid args return 2 and never build the backend or write stdout", async () => {
    const { calls, make } = makeStub();
    const t = io("x");
    const code = await runMem(["bogus"], t, make);
    expect(code).toBe(2);
    expect(calls.built).toBe(0);
    expect(t.stdout()).toBe("");
    expect(t.stderr()).toContain("subcommand");
  });
});
