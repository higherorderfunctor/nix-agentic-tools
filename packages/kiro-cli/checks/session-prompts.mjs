// cspell:ignore nongit untemplated
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
// Usage: `node session-prompts.mjs <acp-server.js> <typescript> [<patcher> <extractor> <src> [<installed worktree bundle>]]`.
const here = import.meta.dirname;
const [
  pinned,
  typescript,
  patcher = path.join(here, "../lib/kiro-bundle-patch.py"),
  extractor = path.join(here, "../extract/prompts.mjs"),
  src = path.join(here, "../src"),
  installed,
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
const patch = (name, entries, worktrees) => {
  const out = path.join(scratch, name);
  fs.mkdirSync(out);
  fs.writeFileSync(path.join(scratch, `${name}.json`), JSON.stringify(entries));
  const selection = path.join(out, "worktrees.json");
  if (worktrees) fs.writeFileSync(selection, JSON.stringify(worktrees));
  const run = spawnSync(
    "python3",
    [
      patcher,
      pinned,
      path.join(scratch, "facts.json"),
      path.join(out, "acp-server.js"),
      "--prompts",
      path.join(scratch, `${name}.json`),
      ...(worktrees ? ["--worktrees", selection] : []),
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
  const parse = (bundle) =>
    ts.createSourceFile(
      bundle,
      fs.readFileSync(bundle, "utf8"),
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.JS,
    );
  const file = parse(patched);
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
  const render = find(
    (n) =>
      ts.isCallExpression(n) &&
      n.arguments[1]?.getText(file).endsWith(".promptContext"),
    agentReader,
  ).expression.text;
  // Kiro's own registration (its `trim` of the text after the front matter) and
  // Mustache render, evaluated from the bundle; only the YAML reader is stubbed.
  let registration = find(
    (n) =>
      ts.isPropertyAssignment(n) &&
      n.name.getText(file) === "prompt" &&
      n.initializer.getText(file).endsWith(".trim()"),
  );
  while (!ts.isFunctionDeclaration(registration))
    registration = registration.parent;
  const frontMatterReader = find(
    (n) =>
      ts.isVariableDeclaration(n) &&
      ts.isObjectBindingPattern(n.name) &&
      n.initializer !== undefined &&
      ts.isCallExpression(n.initializer),
    registration,
  ).initializer.expression.text;
  const declarations = new Map(
    file.statements
      .filter(ts.isFunctionDeclaration)
      .map((f) => [f.name.text, f.getText(file)]),
  );
  const engine = vm.createContext({ a: (f) => f });
  const mustacheName = find(
    (n) => ts.isCallExpression(n) && n.expression.name?.text === "render",
    file.statements.find(named(render)),
  ).expression.expression.text;
  let wrapper = find(
    (n) =>
      ts.isBinaryExpression(n) &&
      n.left.text === mustacheName &&
      ts.isIdentifier(n.right),
  );
  while (!ts.isArrowFunction(wrapper)) wrapper = wrapper.parent;
  for (;;)
    try {
      vm.runInContext(wrapper.body.getText(file), engine);
      break;
    } catch (error) {
      const [, missing] = /^(\S+) is not defined/.exec(error.message) ?? [];
      if (!declarations.has(missing)) throw error;
      vm.runInContext(declarations.get(missing), engine);
    }
  vm.runInContext(declarations.get(render), engine);
  const scope = (known) =>
    new Proxy(known, {
      has: (t, k) => k in t || (typeof k === "string" && !(k in globalThis)),
      get: (t, k) =>
        k in t ? t[k] : k === Symbol.unscopables ? undefined : (x) => x,
    });
  const evaluate = (code, known) =>
    vm.runInNewContext(`with (scope) (${code})`, { scope: scope(known) });
  const kiro = {
    __kiroFillAgent: module.fillAgentDefinition,
    __kiroFillPrompt: module.fillPrompt,
    [render]: engine[render],
  };
  const agentBody = (text) =>
    evaluate(registration.getText(file), {
      [frontMatterReader]: (t) => ({
        data: { name: "x" },
        content: t.slice(t.indexOf("\n---\n", 4) + 5),
      }),
    })(text, { safeParse: (data) => ({ success: true, data }) }).prompt;
  const agent = await evaluate(agentReader.getText(file), kiro);
  const steeringReader = (syntax) => {
    const method = find(
      (n) => ts.isMethodDeclaration(n) && named("createDefinitionForMode")(n),
      syntax,
    );
    const block = find(
      (n) =>
        ts.isObjectLiteralExpression(n) &&
        n.properties.some(
          (p) => p.name?.text === "text" && ts.isAwaitExpression(p.initializer),
        ),
      method,
    );
    const session = method.parameters[0].name.text;
    const binding = block.properties.find((p) => p.name.text === "text")
      .initializer.expression.arguments[1].text;
    const code = `(async () => (${block.getText(syntax)}))()`;
    return (cwd, text, fill = module.fillPrompt) =>
      evaluate(code, {
        ...kiro,
        __kiroFillPrompt: fill,
        [binding]: text,
        [session]: { workspacePaths: [cwd] },
      }).then((filled) => filled.text);
  };
  const steering = steeringReader(file);

  const primary = repo("primary");
  const odd = repo("odd$&name");
  const braced = repo("brace{{native}}{{{raw}}}name");
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
    ["braces in the path", braced, braced],
    ["not git", dir("nongit")],
    ["bare", path.join(scratch, "bare.git")],
    ["separate git dir", path.join(scratch, "sep")],
    ["submodule", path.join(primary, "sub")],
  ];
  const expected = (text, match, root) =>
    root ? text.replace(match, () => `<${path.basename(root)}|${root}>`) : text;
  // Every native variable renders as its own name, so a lost one shows in the result.
  const context = new Proxy(
    {},
    {
      has: () => true,
      get: (_, name) => (typeof name === "string" ? `[${name}]` : undefined),
    },
  );
  // Kiro's render of the body with the filled text inserted after it, as a marker.
  const rendered = (body, match, root) => {
    const marker = "\u0000";
    const output = engine[render](
      root ? body.replace(match, () => marker) : body,
      context,
    );
    return output.replace(marker, () => `<${path.basename(root)}|${root}>`);
  };
  const workspace = (cwd) => ({
    defaultPromptWorkspace: () => ({
      listWorkspaceFolders: () => ({ folders: [{ uri: { fsPath: cwd } }] }),
    }),
    promptContext: context,
  });

  for (const [leaf, id] of Object.entries(agentIds)) {
    const body = agentBody(after[leaf].text);
    for (const [label, cwd, root] of sessions)
      expect(
        `${id}: ${label}`,
        (await agent(
          { id, prompt: body, supportsTemplating: true },
          undefined,
          workspace(cwd),
        )) === rendered(body, entries[`${leaf}-session`].match, root),
        "the prompt Kiro finally renders differs",
      );
  }
  // Without templating, inserted braces reach the prompt as written, unescaped.
  const bracedBody = agentBody(after["agents.workflow.creator"].text);
  const bracedMatch = entries["agents.workflow.creator-session"].match;
  for (const [label, definition, context] of [
    [
      "supportsTemplating false",
      { supportsTemplating: false },
      workspace(braced),
    ],
    [
      "no promptContext",
      { supportsTemplating: true },
      { ...workspace(braced), promptContext: undefined },
    ],
  ])
    expect(
      `untemplated braces: ${label}`,
      (await agent(
        { id: "wf-workflow-creator", prompt: bracedBody, ...definition },
        undefined,
        context,
      )) ===
        bracedBody.replace(
          bracedMatch,
          () => `<${path.basename(braced)}|${braced}>`,
        ),
      "inserted braces were escaped or rendered",
    );
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

  const prohibition = " Do not create the worktree yourself.";
  const routing = { target: orchestration, match: prohibition, replace: "" };
  const setup = stock.split("\n\n")[20].slice(0, 214);
  const absolute = path.join(scratch, "absolute$&{{native}}");
  const variant = async (base, location) => {
    const { out, run } = patch(
      base,
      { ...entries, routing },
      { base, location },
    );
    if (run.status !== 0)
      throw new Error(`worktree patch failed: ${run.stderr}`);
    const { fillPrompt } = await import(path.join(out, "session-prompts.mjs"));
    const { text } = extract(path.join(out, "acp-server.js"))[orchestration];
    expect(base, text === after[orchestration].text.replace(prohibition, ""));
    return (cwd) => steering(cwd, text, fillPrompt);
  };
  const upstreamMode = await variant("upstream", "../{{repo}}-worktrees");
  const remoteMode = await variant("remote-default", absolute);
  const oid = (cwd) => git(cwd, "rev-parse", "HEAD").toString().trim();
  const commit = (cwd, name) =>
    git(cwd, "commit", "-qm", name, "--allow-empty");
  const tracked = oid(odd);
  commit(odd, "remote tip");
  const remoteTip = oid(odd);
  commit(linked, "local tip");
  const local = oid(linked);
  const detached = path.join(scratch, "detached");
  git(odd, "worktree", "add", "-q", "--detach", detached, remoteTip);
  commit(detached, "detached tip");
  const initial = base.replace(prohibition, "");
  const consumerMatch = entries[`${orchestration}-session`].match;
  const sibling = path.join(scratch, "odd$&name-worktrees");
  const baseSentence = (hash) =>
    `When asked to run in a worktree, plan its name and branch and use commit \`${hash}\` as the base.`;
  const setupText = (body, sentence, parent) =>
    body
      .replace(setup, sentence)
      .replace(".worktrees/<name>", () => `${parent}/<name>`);
  const check = async (
    label,
    cwd,
    root,
    hash,
    parent,
    read = upstreamMode,
    reason,
  ) => {
    const body = expected(initial, consumerMatch, root);
    const sentence = reason
      ? `Do not create a worktree this session: ${reason}.`
      : baseSentence(hash);
    expect(
      label,
      (await read(cwd)) === (root ? setupText(body, sentence, parent) : body),
      "base or refusal, location, or surrounding bytes differ",
    );
  };
  await check("local tip", linked, odd, local, sibling);
  await check("detached tip", detached, odd, oid(detached), sibling);
  await check("primary tip", odd, odd, remoteTip, sibling);
  await check("no root", dir("nongit"));
  for (const name of ["origin", "upstream"])
    git(odd, "remote", "add", name, ".");
  const tracking = "refs/remotes/upstream/topic";
  git(odd, "update-ref", tracking, tracked);
  git(linked, "branch", "--set-upstream-to=upstream/topic");
  await check("upstream tip", linked, odd, tracked, sibling);
  const remoteHead = "refs/remotes/upstream/HEAD";
  const trunk = "refs/remotes/upstream/trunk";
  git(odd, "update-ref", trunk, remoteTip);
  git(odd, "symbolic-ref", remoteHead, trunk);
  await check("symbolic default", linked, odd, remoteTip, absolute, remoteMode);
  if (installed) {
    const { fillPrompt } = await import(
      path.join(path.dirname(installed), "session-prompts.mjs")
    );
    const { text } = extract(installed)[orchestration];
    const read = steeringReader(parse(installed));
    expect(
      "packaged worktrees-only build preserves the stock literal",
      text === stock,
    );
    expect(
      "packaged worktrees-only reader uses the upstream commit and sibling location",
      (await read(linked, text, fillPrompt)) ===
        setupText(stock, baseSentence(tracked), sibling),
    );
  }

  const withGitEnv = async (vars, run) => {
    const before = Object.fromEntries(
      Object.keys(vars).map((key) => [key, process.env[key]]),
    );
    try {
      Object.assign(process.env, vars);
      await run();
    } finally {
      for (const [key, value] of Object.entries(before)) {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      }
    }
  };
  const branchRemote = `branch.${git(linked, "branch", "--show-current").toString().trim()}.remote`;
  await withGitEnv(
    {
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: branchRemote,
      GIT_CONFIG_VALUE_0: "missing",
      GIT_OBJECT_DIRECTORY: path.join(primary, ".git", "objects"),
    },
    () =>
      check(
        "inherited Git config and object directory are ignored",
        linked,
        odd,
        tracked,
        sibling,
      ),
  );

  const refuses = (label, read, parent, reason) =>
    check(label, linked, odd, undefined, parent, read, reason);
  git(odd, "update-ref", "--no-deref", "-d", remoteHead);
  await refuses(
    "missing symbolic default",
    remoteMode,
    absolute,
    "missing local symbolic remote HEAD",
  );
  git(odd, "update-ref", "-d", tracking);
  await refuses(
    "stale upstream",
    upstreamMode,
    sibling,
    "@{upstream} does not resolve to a local commit",
  );
  git(linked, "config", branchRemote, "missing");
  await refuses(
    "configured remote is absent despite origin",
    remoteMode,
    absolute,
    "the configured branch remote does not exist",
  );
  git(linked, "config", "--unset", branchRemote);
  git(odd, "remote", "remove", "origin");
  git(odd, "remote", "add", "mirror", ".");
  await refuses(
    "multiple remotes without origin",
    remoteMode,
    absolute,
    "no remote can be selected for remote-default",
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
      "delimiter change beside a placeholder",
      {
        x: {
          target: orchestration,
          match: entries[`${orchestration}-session`].match,
          replace: "{{=<% %>=}}{{repo}}",
        },
      },
      "prompts.x",
    ],
    [
      "spaced delimiter change beside a placeholder",
      {
        x: {
          target: orchestration,
          match: entries[`${orchestration}-session`].match,
          replace: "{{ =<% %>=}}{{repo}}",
        },
      },
      "prompts.x",
    ],
    [
      "BOM-spaced delimiter change beside a placeholder",
      {
        x: {
          target: orchestration,
          match: entries[`${orchestration}-session`].match,
          replace: "{{\uFEFF=<% %>=}}{{repo}}",
        },
      },
      "prompts.x",
    ],
    [
      "match touching the trimmed end",
      {
        x: {
          target: "agents.workflow.planner",
          match: facts["agents.workflow.planner"].text.slice(-12),
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
  "PASS: session-prompts fills both readers and worktree setup per session; unresolved bases refuse",
);
