// What the TS Agent SDK sends to the CLI when a host calls it directly (run via sdk-ts.sh).
//
// usage: node sdk-ts.mjs <sdk.mjs> [variant...]
//
// Imports the SDK bundled in nixpkgs' claude-agent-acp and runs one query("hi") per variant with
// pathToClaudeCodeExecutable = sdk-recorder.sh, which prepends a wrapper-owned
// --append-system-prompt-file (APPFILE-9999) and records argv and the SDK's stream-json stdin.
// Against sysprompt/mock.py with a fake key. Prints per variant:
//
//   <variant>: sdk=<ver> init_prompt=<prompt fields in initialize> argv_prompt=<flags> tokens=<sentinels>
//
// default        query options {} (no systemPrompt)
// preset-append  systemPrompt {type:"preset", preset:"claude_code", append:"...TSAPPEND-6464."}
// string         systemPrompt "...TSSTRING-6565." (replaces the base)
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const sysprompt = path.join(here, "..", "sysprompt");
const TOKEN = /\b[A-Z]{4,}-\d{4}\b/g;
const PRESET = { type: "preset", preset: "claude_code" };
const VARIANTS = {
  default: {},
  "preset-append": {
    systemPrompt: { ...PRESET, append: "TS append sentinel: TSAPPEND-6464." },
  },
  string: { systemPrompt: "TS string sentinel: TSSTRING-6565." },
};
const PROMPT_FIELDS = [
  "systemPrompt",
  "appendSystemPrompt",
  "appendSubagentSystemPrompt",
  "excludeDynamicSections",
];
const PROMPT_FLAGS = new Set([
  "--system-prompt",
  "--system-prompt-file",
  "--append-system-prompt",
  "--append-system-prompt-file",
]);

function workdir() {
  if (process.env.PROBE_OUT) {
    const dir = path.join(process.env.PROBE_OUT, "claude-sdk-ts");
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  }
  return fs.mkdtempSync(
    path.join(os.tmpdir(), "delegate-probe-claude-sdk-ts-"),
  );
}

function freePort() {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function waitPort(port) {
  for (let i = 0; i < 50; i++) {
    const ok = await new Promise((resolve) => {
      const s = net.connect(port, "127.0.0.1", () => {
        s.end();
        resolve(true);
      });
      s.on("error", () => resolve(false));
    });
    if (ok) return;
    await new Promise((r) => setTimeout(r, 100));
  }
}

// [argv, initialize request] of the spawn whose stdin carried an initialize.
function spawnCapture(out) {
  for (const name of fs.readdirSync(out).sort()) {
    if (!name.startsWith("stdin-")) continue;
    for (const line of fs
      .readFileSync(path.join(out, name), "utf8")
      .split("\n")) {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (
        msg.type === "control_request" &&
        msg.request?.subtype === "initialize"
      ) {
        const pid = name.slice("stdin-".length, -".jsonl".length);
        const argv = fs
          .readFileSync(path.join(out, `argv-${pid}.txt`), "utf8")
          .split("\n");
        return [argv, msg.request];
      }
    }
  }
  return [[], {}];
}

function mainSystem(reqs) {
  for (const name of fs.readdirSync(reqs).sort()) {
    if (!name.endsWith(".json")) continue;
    const rec = JSON.parse(fs.readFileSync(path.join(reqs, name), "utf8"));
    if (
      rec.path.startsWith("/v1/messages") &&
      !rec.path.includes("count_tokens") &&
      rec.body.tools
    ) {
      return rec.body.system ?? [];
    }
  }
  return [];
}

async function run(sdk, version, work, variant) {
  const out = path.join(work, variant);
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(path.join(out, "reqs"), { recursive: true });
  const cwd = path.join(out, "cwd");
  fs.cpSync(path.join(sysprompt, "cwd"), cwd, { recursive: true });
  spawnSync("git", ["-C", cwd, "init", "-q", "-b", "main"], {
    stdio: "inherit",
  });
  const port = await freePort();
  const mock = spawn("python3", ["-I", path.join(sysprompt, "mock.py")], {
    env: {
      ...process.env,
      MOCK_PORT: String(port),
      MOCK_DIR: path.join(out, "reqs"),
    },
    stdio: "ignore",
  });
  try {
    await waitPort(port);
    const env = {
      PATH: process.env.PATH,
      CLAUDE_BIN: process.env.CLAUDE_BIN,
      HOME: out,
      ANTHROPIC_API_KEY: "mock-offline-not-a-key",
      ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      CLAUDE_CONFIG_DIR: path.join(out, "config"),
      DISABLE_TELEMETRY: "1",
      RECORDER_INJECT_FILE: path.join(sysprompt, "append.md"),
      RECORDER_OUT: out,
    };
    const q = sdk.query({
      prompt: "hi",
      options: {
        ...VARIANTS[variant],
        cwd,
        env,
        model: "haiku",
        pathToClaudeCodeExecutable: path.join(here, "sdk-recorder.sh"),
      },
    });
    for await (const _ of q) {
      // drain
    }
  } finally {
    mock.kill();
  }
  const [argv, init] = spawnCapture(out);
  const flags = argv
    .map((a, i) =>
      PROMPT_FLAGS.has(a) ? `${a}=${JSON.stringify(argv[i + 1])}` : null,
    )
    .filter(Boolean);
  const fields = Object.fromEntries(
    PROMPT_FIELDS.filter((k) => init[k] !== undefined && init[k] !== null).map(
      (k) => [k, init[k]],
    ),
  );
  const system = mainSystem(path.join(out, "reqs"));
  const tokens = [
    ...new Set(system.flatMap((b) => b.text.match(TOKEN) ?? [])),
  ].sort();
  console.log(
    `${variant}: sdk=${version} init_prompt=${JSON.stringify(fields)} ` +
      `argv_prompt=${flags.join(" ") || "-"} sys=${JSON.stringify(system.map((b) => b.text.length))} ` +
      `tokens=${tokens.join(",") || "-"}`,
  );
  console.log(`  captures: ${out}`);
}

const [sdkPath, ...names] = process.argv.slice(2);
const sdk = await import(pathToFileURL(sdkPath).href);
const pkg = JSON.parse(
  fs.readFileSync(path.join(path.dirname(sdkPath), "package.json"), "utf8"),
);
const work = workdir();
for (const name of names.length ? names : Object.keys(VARIANTS)) {
  if (!(name in VARIANTS)) {
    console.error(`unknown variant: ${name}`);
    process.exit(2);
  }
  await run(sdk, pkg.version, work, name);
}
