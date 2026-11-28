// cspell:ignore idents nongit
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";

// Proves the per-session fill on the pinned bundle: it patches a copy with
// `{{primary}}`/`{{repo}}` entries, finds the two readers of the prompts by
// AST, and runs them (Kiro's `subagentPrompt` and the orchestration block of
// `createDefinitionForMode`) for several working directories in turn. Vendor
// text is read at run time to choose anchors and is never printed.
// Usage: `node session-prompts.mjs <acp-server.js> <typescript> [<patcher> <extractor> <src>]`.
const here = import.meta.dirname;
const [
  pinned,
  typescript,
  patcher = path.join(here, "../lib/kiro-bundle-patch.py"),
  extractor = path.join(here, "../extract/prompts.mjs"),
  src = path.join(here, "../src"),
] = process.argv.slice(2);
const ts = createRequire(import.meta.url)(typescript);
const scratch = fs.realpathSync(
  fs.mkdtempSync(path.join(os.tmpdir(), "session-prompts-")),
);
const failures = [];
const expect = (name, ok, detail = "") =>
  ok || failures.push(`${name}: ${detail}`);
const extract = (bundle) =>
  JSON.parse(
    execFileSync(process.execPath, [extractor, bundle, typescript], {
      maxBuffer: 1 << 26,
    }),
  );
const patch = (name, entries) => {
  const out = path.join(scratch, name);
  fs.mkdirSync(out);
  fs.writeFileSync(path.join(scratch, `${name}.json`), JSON.stringify(entries));
  const run = spawnSync(
    "python3",
    [
      patcher,
      pinned,
      path.join(scratch, "facts.json"),
      path.join(out, "acp-server.js"),
      "--prompts",
      path.join(scratch, `${name}.json`),
      "--session-fill",
      src,
    ],
    { encoding: "utf8" },
  );
  return { out, run };
};

const git = (cwd, ...args) =>
  execFileSync(
    "git",
    [
      "-c",
      "user.name=n",
      "-c",
      "user.email=e",
      "-c",
      "protocol.file.allow=always",
      "-C",
      cwd,
      ...args,
    ],
    {
      env: {
        ...process.env,
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_NOSYSTEM: "1",
      },
      stdio: "pipe",
    },
  );
const dir = (...parts) =>
  fs.mkdirSync(path.join(scratch, ...parts), { recursive: true }) ??
  path.join(scratch, ...parts);
const repo = (name) => (
  git(dir(name), "init", "-q"),
  git(path.join(scratch, name), "commit", "-q", "--allow-empty", "-m", "x"),
  path.join(scratch, name)
);

try {
  const facts = extract(pinned);
  fs.writeFileSync(path.join(scratch, "facts.json"), JSON.stringify(facts));
  const orchestration = "workflow.orchestration";
  const agentIds = {
    "agents.workflow.creator": "wf-workflow-creator",
    "agents.workflow.planner": "wf-planner",
  };
  // A 24-character window at or after `from` that has no braces or newlines and occurs once.
  const window = (text, from) => {
    for (let at = from; at < text.length; at++) {
      const found = text.slice(at, at + 24);
      if (
        !/[{}\n]/.test(found) &&
        text.indexOf(found) === text.lastIndexOf(found)
      )
        return found;
    }
  };
  const entries = {};
  for (const [leaf, { text }] of Object.entries(facts)) {
    const from = text.startsWith("---\n") ? text.indexOf("\n---\n", 4) + 5 : 40;
    entries[`${leaf}-session`] = {
      target: leaf,
      match: window(text, from),
      replace: "<{{repo}}|{{primary}}>",
    };
    entries[`${leaf}-literal`] = {
      target: leaf,
      match: window(text, from + 500),
      replace: "LITERAL",
    };
  }
  const { out, run } = patch("filled", entries);
  expect("patch", run.status === 0, run.stderr);
  const patched = path.join(out, "acp-server.js");
  const bundle = fs.readFileSync(patched, "utf8");
  const file = ts.createSourceFile(
    patched,
    bundle,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.JS,
  );
  expect("patched bundle parses", file.parseDiagnostics.length === 0);
  const after = extract(patched);
  const module = await import(path.join(out, "session-prompts.mjs"));

  // The readers, found as the vendor names them, not as the patcher does.
  const find = (test, within = file) => {
    let found;
    (function visit(node) {
      if (!found && test(node)) found = node;
      else ts.forEachChild(node, visit);
    })(within);
    return found;
  };
  const named = (name) => (node) => node.name?.text === name;
  const registered = find(
    (n) => ts.isCallExpression(n) && n.arguments[1]?.text === "subagentPrompt",
  ).arguments[0].text;
  const agentReader = find(
    (n) => ts.isFunctionDeclaration(n) && named(registered)(n),
  );
  const method = find(
    (n) => ts.isMethodDeclaration(n) && named("createDefinitionForMode")(n),
  );
  const block = find(
    (n) =>
      ts.isObjectLiteralExpression(n) &&
      n.properties.some(
        (p) => p.name?.text === "text" && ts.isAwaitExpression(p.initializer),
      ),
    method,
  );
  expect(
    "orchestration block is in createDefinitionForMode",
    block !== undefined,
  );
  const render = find(
    (n) =>
      ts.isCallExpression(n) &&
      n.arguments[1]?.getText(file).endsWith(".promptContext"),
    agentReader,
  ).expression.text;
  const session = method.parameters[0].name.text;
  const scope = (known) =>
    new Proxy(known, {
      has: (t, k) => k in t || (typeof k === "string" && !(k in globalThis)),
      get: (t, k) =>
        k in t ? t[k] : k === Symbol.unscopables ? undefined : (x) => x,
    });
  const seen = [];
  const mustache = (template, context) => (
    seen.push(template),
    template.replace(/\{\{(\w+)\}\}/g, (_, name) => context[name] ?? "")
  );
  const evaluate = (code, known) =>
    vm.runInNewContext(`with (scope) (${code})`, {
      scope: scope({
        __kiroFillAgent: module.fillAgentDefinition,
        __kiroFillPrompt: module.fillPrompt,
        [render]: mustache,
        ...known,
      }),
    });
  const agent = await evaluate(agentReader.getText(file), {});
  const steering = (cwd, text) => {
    const array = find(
      (n) => ts.isArrayLiteralExpression(n) && n.elements.includes(block),
      method,
    );
    const spreads = Object.fromEntries(
      array.elements
        .filter(ts.isSpreadElement)
        .map((s) => [s.expression.text, []]),
    );
    const idents = Object.fromEntries(
      array.elements
        .filter((e) => e !== block)
        .flatMap((e) =>
          ts.isObjectLiteralExpression(e)
            ? [[e.properties[0].initializer.text, ""]]
            : [],
        ),
    );
    const binding = block.properties.find((p) => p.name.text === "text")
      .initializer.expression.arguments[1].text;
    return evaluate(`(async () => (${array.getText(file)}))()`, {
      ...idents,
      ...spreads,
      [binding]: text,
      [session]: { workspacePaths: [cwd] },
    }).then((blocks) => blocks.at(-1).text);
  };

  const primary = repo("primary");
  const odd = repo("odd$&name");
  git(odd, "worktree", "add", "-q", path.join(scratch, "linked"));
  git(dir("bare.git"), "init", "-q", "--bare");
  git(
    dir("sep"),
    "init",
    "-q",
    "--separate-git-dir",
    path.join(scratch, "sep.git"),
  );
  git(primary, "submodule", "add", "-q", odd, "sub");
  // [label, session cwd, the root it must resolve to]; a cwd without one keeps the original text.
  const sessions = [
    ["primary checkout", primary, primary],
    [
      "linked worktree of another repository",
      path.join(scratch, "linked"),
      odd,
    ],
    ["primary again", primary, primary],
    ["not git", dir("nongit")],
    ["bare", path.join(scratch, "bare.git")],
    ["separate git dir", path.join(scratch, "sep")],
    ["submodule", path.join(primary, "sub")],
  ];
  const expected = (text, match, root) =>
    root ? text.replace(match, () => `<${path.basename(root)}|${root}>`) : text;
  const workspace = (cwd) => ({
    defaultPromptWorkspace: () => ({
      listWorkspaceFolders: () => ({ folders: [{ uri: { fsPath: cwd } }] }),
    }),
    promptContext: {},
  });
  const natives = (text) => text.match(/\{\{[#/^]?\w+\}\}/g);

  for (const [leaf, id] of Object.entries(agentIds)) {
    const body = after[leaf].text.slice(
      after[leaf].text.indexOf("\n---\n", 4) + 5,
    );
    for (const [label, cwd, root] of sessions) {
      seen.length = 0;
      await agent(
        { id, prompt: body, supportsTemplating: true },
        undefined,
        workspace(cwd),
      );
      const match = entries[`${leaf}-session`].match;
      expect(
        `${id}: ${label}`,
        seen[0] === expected(body, match, root),
        "the text Kiro renders differs",
      );
      expect(
        `${id}: ${label} native variables`,
        String(natives(seen[0])) === String(natives(body)),
      );
    }
  }
  const stock = facts[orchestration].text;
  const base = after[orchestration].text;
  for (const [label, cwd, root] of sessions)
    expect(
      `orchestration: ${label}`,
      (await steering(cwd, base)) ===
        expected(base, entries[`${orchestration}-session`].match, root),
      "the steering block differs",
    );
  process.env.GIT_DIR = path.join(primary, ".git");
  const [, linked, linkedRoot] = sessions[1];
  expect(
    "inherited GIT_DIR is ignored",
    (await steering(linked, base)) ===
      expected(base, entries[`${orchestration}-session`].match, linkedRoot),
  );
  delete process.env.GIT_DIR;
  expect(
    "literal siblings apply at build time",
    base.includes("LITERAL") && !stock.includes("LITERAL"),
  );

  const duplicate = entries[`${orchestration}-literal`].match;
  const refused = [
    [
      "front matter selection",
      {
        x: {
          target: "agents.workflow.creator",
          match: "name: wf-workflow-creator",
          replace: "{{repo}}",
        },
      },
      "prompts.x",
    ],
    [
      "duplicated match",
      {
        a: {
          target: orchestration,
          match: duplicate,
          replace: entries[`${orchestration}-session`].match,
        },
        b: entries[`${orchestration}-session`],
      },
      "prompts.b",
    ],
  ];
  for (const [label, bad, name] of refused) {
    const { run } = patch(`bad-${label.replace(/\W/g, "")}`, bad);
    expect(
      label,
      run.status === 1 &&
        run.stderr.includes(name) &&
        !run.stderr.includes(duplicate),
      run.stderr.slice(0, 200),
    );
  }
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}
if (failures.length) {
  console.error(failures.map((f) => `FAIL: session-prompts: ${f}`).join("\n"));
  process.exit(1);
}
console.log(
  "PASS: session-prompts fills both readers per session and keeps the original without a root",
);
