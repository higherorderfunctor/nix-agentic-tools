import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Checks extract/prompts.mjs on a synthetic bundle shaped like the engine's
// (lazy initializer writes, an aliased agent id, shadowed bindings, decoys, a
// non-ASCII prefix) and then on the pinned real bundle.
// Usage: `node prompt-extract.mjs <typescript> <acp-server.js>`.
const [typescript, pinnedPath] = process.argv.slice(2);
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "prompt-extract-"));
const run = (bundle) => {
  const file = path.join(scratch, "bundle.js");
  fs.writeFileSync(file, bundle);
  const extractor = path.join(import.meta.dirname, "../extract/prompts.mjs");
  return spawnSync(process.execPath, [extractor, file, typescript], {
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
bad.forEach(([key, reason, from, to], row) => {
  const outcome = run(good.replace(from, to));
  expect(
    `bad row ${row} (${key}: ${to})`,
    good.includes(from) &&
      outcome.status === 1 &&
      outcome.stderr.includes(`${key}: `) &&
      outcome.stderr.includes(reason),
    `status ${outcome.status}, stderr ${outcome.stderr.trim()}`,
  );
});

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
