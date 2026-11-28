import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Checks extract/prompts.mjs on a synthetic bundle shaped like the engine's
// (lazy initializer writes, an aliased agent id, shadowed bindings, decoys, a
// non-ASCII prefix) and then on the pinned real bundle.
// Usage: `node prompt-extract.mjs <typescript> <acp-server.js> [<prompts.mjs>]`;
// the extractor defaults to its sibling in the source tree, and the Nix check
// passes it explicitly because the check file alone is copied to the store.
const [
  typescript,
  pinnedPath,
  extractor = path.join(import.meta.dirname, "../extract/prompts.mjs"),
] = process.argv.slice(2);
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "prompt-extract-"));
const run = (bundle, ...flags) => {
  const file = path.join(scratch, "bundle.js");
  fs.writeFileSync(file, bundle);
  return spawnSync(process.execPath, [extractor, file, typescript, ...flags], {
    encoding: "utf8",
    maxBuffer: 1 << 26,
  });
};
const facts = (outcome) => (outcome.status ? {} : JSON.parse(outcome.stdout));

const creator = "agents.workflow.creator";
const planner = "agents.workflow.planner";
const orchestration = "workflow.orchestration";
const raw = {
  [creator]: String.raw`'---\nname: wf-workflow-creator\nbody é \'quoted\'\n'`,
  [planner]: `\`${String.raw`---\nname: wf-planner\n{{#run}}plan ☃ {{/run}}`}\``,
  [orchestration]: String.raw`"# Workflow Orchestration\n\nRun {{#steps}}\"{{name}}\"{{/steps}}\n"`,
};
// Decoded text and literal kind each raw literal must produce.
const expected = {
  [creator]: [
    "StringLiteral",
    "---\nname: wf-workflow-creator\nbody é 'quoted'\n",
  ],
  [planner]: [
    "NoSubstitutionTemplateLiteral",
    "---\nname: wf-planner\n{{#run}}plan ☃ {{/run}}",
  ],
  [orchestration]: [
    "StringLiteral",
    '# Workflow Orchestration\n\nRun {{#steps}}"{{name}}"{{/steps}}\n',
  ],
};
const good = `var prefix="é😀";
var decoy=['see # Workflow Orchestration\\n'];register(["wf-planner","x"]);
var other=[{id:"wf-planner"}],Cr,Pl,Id,Orch;
function shadow(){let Cr="s",Pl="s";Cr="t";Pl="t"}
var init=E(()=>{Id="wf-workflow-creator";Cr=${raw[creator]};Pl=${raw[planner]}});
Orch=${raw[orchestration]};
var table=[["other",Orch],[Id,Cr],["wf-planner",Pl]];`;

const failures = [];
const expect = (name, ok, detail) => ok || failures.push(`${name}: ${detail}`);

// Valid bundle: exactly these keys, decoded text, and UTF-8 byte spans found
// independently by a byte search of the raw literal.
const found = facts(run(good));
expect(
  "fixture keys",
  Object.keys(found).sort().join() === Object.keys(expected).sort().join(),
  Object.keys(found).join(),
);
for (const [key, [kind, text]] of Object.entries(expected)) {
  const start = Buffer.from(good).indexOf(raw[key]);
  const end = start + Buffer.byteLength(raw[key]);
  const want = JSON.stringify({ end, kind, start, text });
  expect(
    key,
    JSON.stringify(found[key]) === want,
    `got ${JSON.stringify(found[key])}`,
  );
}

// `--digest` keeps the spans and kind, drops the text, and adds the SHA-256 of
// the text's UTF-8 bytes (the raw literal's escapes decoded first), which the
// committed facts carry instead of vendor text.
const digested = facts(run(good, "--digest"));
for (const [key, [kind, text]] of Object.entries(expected)) {
  const { end, start } = found[key];
  const sha256 = createHash("sha256").update(text).digest("hex");
  expect(
    `${key} digest`,
    JSON.stringify(digested[key]) ===
      JSON.stringify({ end, kind, sha256, start }),
    `got ${JSON.stringify(digested[key])}`,
  );
}

// One case per guard. Each edits the valid bundle (`[from, to]` pairs; a case
// whose `from` is absent fails, so a fixture change cannot silently void it).
// A refusing case must exit 1 naming `key` and `reason`; a case with a null
// reason must still resolve the creator to the valid bundle's text.
const notStatic = "not one static string";
const table = "var table";
const binding = { [creator]: "Cr", [orchestration]: "Orch", [planner]: "Pl" };
const refuse = (key, reason, label, ...edits) => ({
  edits,
  key,
  label,
  reason,
});
const accept = (label, ...edits) => refuse(creator, null, label, ...edits);
const beforeTable = (code) => [table, `${code};${table}`];
const withLiteral = (key, label, replacement) =>
  refuse(key, notStatic, label, [
    `${binding[key]}=${raw[key]}`,
    `${binding[key]}=${replacement}`,
  ]);
const dropCr = [",Cr,Pl,Id,Orch;", ",Pl,Id,Orch;"];
const dropCrWrite = [`Cr=${raw[creator]};`, ""];
const creatorTable = 'var table=[["other",Orch],[Id,Cr],["wf-planner",Pl]];';
const cases = [
  refuse(creator, "0 registration rows", "no creator row", ["[Id,Cr],", ""]),
  refuse(creator, "0 registration rows", "no creator id", [
    'Id="wf-workflow-creator";',
    "",
  ]),
  refuse(creator, notStatic, "second write in a declaration", [
    "Cr,Pl,",
    'Cr="late",Pl,',
  ]),
  // Each gives `Cr` a second, dynamic write. `Cr++`, `Cr+=` and `Cr||=` are
  // writes only through ts.isWriteAccess; the destructuring and loop targets
  // below are writes only through isAssignmentTarget.
  ...[
    "Cr++",
    "Cr+='x'",
    "Cr||='x'",
    "[Cr]=[dyn()]",
    "[Cr=1]=dyn()",
    "[...Cr]=dyn()",
    "[...[Cr]]=dyn()",
    "({body:Cr}=dyn())",
    "({Cr}=dyn())",
    "({...Cr}=dyn())",
    "for(Cr of dyn()){}",
    "for(Cr in dyn()){}",
    "for([other,...Cr] of dyn()){}",
    "var [Cr]=dyn()",
    "for(var [Cr] of dyn()){}",
  ].map((write) =>
    refuse(creator, notStatic, `write ${write}`, beforeTable(write)),
  ),
  // The only write is the destructuring target's own default, whose value is
  // the bundle's literal but whose source is `dyn()`.
  refuse(creator, notStatic, "only write is a target default", dropCrWrite, [
    table,
    `[Cr="creator"]=dyn();${table}`,
  ]),
  refuse(planner, "2 registration rows", "second planner row", [
    table,
    `var again=[["wf-planner",Pl]];${table}`,
  ]),
  refuse(planner, notStatic, "alias cycle", [
    '["wf-planner",Pl]];',
    '["wf-planner",Cy]];var Cy=Dy,Dy=Cy;',
  ]),
  withLiteral(planner, "template substitution", "`${x}`"),
  withLiteral(planner, "tagged template", "tag`x`"),
  refuse(
    "bundle",
    "uses with",
    "with statement",
    beforeTable("with({}){Cr=1}"),
  ),
  refuse(
    "bundle",
    "calls eval",
    "direct eval",
    beforeTable('eval("Cr=dyn()")'),
  ),
  refuse("bundle", "not valid JavaScript", "syntax error", [
    '["wf-planner",Pl]];',
    '["wf-planner",Pl]];)',
  ]),
  refuse(orchestration, "0 headed literals", "heading removed", [
    '"# Workflow Orchestration',
    '"# Other',
  ]),
  refuse(orchestration, "2 headed literals", "second heading", [
    table,
    `var more="# Workflow Orchestration\\n";${table}`,
  ]),
  withLiteral(
    orchestration,
    "heading template substitution",
    "`# Workflow Orchestration\\n${x}`",
  ),
  withLiteral(
    orchestration,
    "heading tagged template",
    "tag`# Workflow Orchestration\\n`",
  ),
  // Every declaration of `Cr` must be a plain variable declaration, whatever
  // else shares its symbol.
  refuse(
    creator,
    notStatic,
    "for-in head with initializer",
    [
      ",Cr,Pl,Id,Orch;",
      `,Pl,Id,Orch;for(var Cr=${raw[creator]} in{changed:1}){}`,
    ],
    dropCrWrite,
  ),
  refuse(creator, notStatic, "parameter beside var", dropCr, dropCrWrite, [
    creatorTable,
    `function f(Cr){var Cr=${raw[creator]};${creatorTable}}`,
  ]),
  refuse(creator, notStatic, "function beside var", [
    table,
    "function Cr(){}var table",
  ]),
  // Reads and value-position assignments are not writes of a destructuring
  // target.
  ...["[...Cr]", "{...Cr}", "[...{a:Cr}]"].map((read) =>
    accept(`spread read ${read}`, beforeTable(`var copy=${read}`)),
  ),
  ...["[Cr=RAW]", "{body:Cr=RAW}"].map((value) =>
    accept(
      `value-position assignment ${value}`,
      dropCrWrite,
      beforeTable(`var a=${value.replace("RAW", raw[creator])}`),
    ),
  ),
];
const applyEdits = (edits) =>
  edits.every(([from]) => good.includes(from))
    ? edits.reduce((text, [from, to]) => text.replace(from, () => to), good)
    : null;
for (const { edits, key, label, reason } of cases) {
  const bundle = applyEdits(edits);
  const outcome = bundle === null ? null : run(bundle);
  expect(
    `${reason ? "refusal" : "passing"} case (${key}: ${label})`,
    outcome !== null &&
      (reason
        ? outcome.status === 1 &&
          outcome.stderr.includes(`${key}: `) &&
          outcome.stderr.includes(reason)
        : outcome.status === 0 &&
          facts(outcome)[creator]?.text === expected[creator][1]),
    outcome
      ? `status ${outcome.status}, stderr ${outcome.stderr.trim()}`
      : "an edit does not apply to the valid bundle",
  );
}

// Pinned real bundle: three distinct bodies, each starting with its anchor and
// spanning a delimited literal. Contents are never printed.
const pinned = run(fs.readFileSync(pinnedPath));
expect("pinned", pinned.status === 0, pinned.stderr);
const real = facts(pinned);
const bytes = fs.readFileSync(pinnedPath);
const anchors = {
  [creator]: "---\nname: wf-workflow-creator\n",
  [planner]: "---\nname: wf-planner\n",
  [orchestration]: "# Workflow Orchestration\n",
};
for (const [key, anchor] of Object.entries(anchors)) {
  const { end, start, text } = real[key] ?? {};
  expect(
    `pinned ${key}`,
    text?.startsWith(anchor) &&
      bytes[start] === bytes[end - 1] &&
      end - start >= Buffer.byteLength(text),
    "anchor or span mismatch",
  );
}
expect(
  "pinned distinct",
  new Set(Object.values(real).map((fact) => fact.text)).size === 3,
  "bodies are not three distinct texts",
);

fs.rmSync(scratch, { recursive: true });
if (failures.length) {
  process.stderr.write(`${failures.join("\n")}\n`);
  process.exit(1);
}
