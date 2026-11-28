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

// One bad bundle per guard: `from` is replaced by `to`, and the run must fail
// naming the fact key and the reason.
const notStatic = "not one static string";
const table = "var table";
const binding = { [creator]: "Cr", [orchestration]: "Orch", [planner]: "Pl" };
const withLiteral = (key, replacement) => [
  key,
  notStatic,
  `${binding[key]}=${raw[key]}`,
  `${binding[key]}=${replacement}`,
];
// A write the extractor must see: each one gives `Cr` a second, dynamic write.
const dynamicWrites = [
  "[Cr]=[dyn()]",
  "[Cr=1]=dyn()",
  "[...Cr]=dyn()",
  "[...[Cr]]=dyn()",
  "({body:Cr}=dyn())",
  "({Cr}=dyn())",
  "({...Cr}=dyn())",
  "for(Cr of dyn()){}",
  "for(Cr in dyn()){}",
  "var [Cr]=dyn()",
  "for(var [Cr] of dyn()){}",
];
const bad = [
  [creator, "0 registration rows", "[Id,Cr],", ""],
  [creator, "0 registration rows", 'Id="wf-workflow-creator";', ""],
  [creator, notStatic, "Cr,Pl,", 'Cr="late",Pl,'],
  ...dynamicWrites.map((write) => [
    creator,
    notStatic,
    table,
    `${write};${table}`,
  ]),
  [
    planner,
    "2 registration rows",
    table,
    `var again=[["wf-planner",Pl]];${table}`,
  ],
  [
    planner,
    notStatic,
    '["wf-planner",Pl]];',
    '["wf-planner",Cy]];var Cy=Dy,Dy=Cy;',
  ],
  withLiteral(planner, "`${x}`"),
  withLiteral(planner, "tag`x`"),
  ["bundle", "uses with", table, `with({}){Cr="changed"}${table}`],
  [orchestration, "0 headed literals", '"# Workflow Orchestration', '"# Other'],
  [
    orchestration,
    "2 headed literals",
    table,
    `var more="# Workflow Orchestration\\n";${table}`,
  ],
  withLiteral(orchestration, "`# Workflow Orchestration\\n${x}`"),
  withLiteral(orchestration, "tag`# Workflow Orchestration\\n`"),
];
// Rows that need several edits at once: every declaration of `Cr` must be a
// plain variable declaration, whatever else shares its symbol.
const dropCr = [",Cr,Pl,Id,Orch;", ",Pl,Id,Orch;"];
const dropCrWrite = [`Cr=${raw[creator]};`, ""];
const creatorTable = 'var table=[["other",Orch],[Id,Cr],["wf-planner",Pl]];';
const edited = [
  [
    "for-in head with initializer",
    [
      [
        ",Cr,Pl,Id,Orch;",
        `,Pl,Id,Orch;for(var Cr=${raw[creator]} in{changed:1}){}`,
      ],
      dropCrWrite,
    ],
  ],
  [
    "parameter beside var",
    [
      dropCr,
      dropCrWrite,
      [creatorTable, `function f(Cr){var Cr=${raw[creator]};${creatorTable}}`],
    ],
  ],
  ["function beside var", [[table, "function Cr(){}var table"]]],
].map(([label, edits]) => [
  creator,
  notStatic,
  label,
  edits.reduce((text, [from, to]) => text.replace(from, to), good),
  edits.every(([from]) => good.includes(from)),
]);
[
  ...bad.map(([key, reason, from, to]) => [
    key,
    reason,
    to,
    good.replace(from, to),
    good.includes(from),
  ]),
  ...edited,
].forEach(([key, reason, label, bundle, applies], row) => {
  const outcome = run(bundle);
  expect(
    `bad row ${row} (${key}: ${label})`,
    applies &&
      outcome.status === 1 &&
      outcome.stderr.includes(`${key}: `) &&
      outcome.stderr.includes(reason),
    `status ${outcome.status}, stderr ${outcome.stderr.trim()}`,
  );
});

// Reads and value-position assignments are not writes of a destructuring
// target: each must still resolve, to the same creator text as the good bundle.
const reads = ["[...Cr]", "{...Cr}", "[...{a:Cr}]"].map((read) => [
  `spread read ${read}`,
  [[table, `var copy=${read};${table}`]],
]);
const valueWrites = ["[Cr=RAW]", "{body:Cr=RAW}"].map((value) => [
  `value-position assignment ${value}`,
  [
    dropCrWrite,
    [table, `var a=${value.replace("RAW", raw[creator])};${table}`],
  ],
]);
for (const [label, edits] of [...reads, ...valueWrites]) {
  const outcome = run(
    edits.reduce((text, [from, to]) => text.replace(from, to), good),
  );
  expect(
    `passing row (${label})`,
    outcome.status === 0 &&
      facts(outcome)[creator]?.text === expected[creator][1],
    `status ${outcome.status}, stderr ${outcome.stderr.trim()}`,
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
