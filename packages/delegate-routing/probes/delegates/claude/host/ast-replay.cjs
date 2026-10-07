// codex:H — prints the host-control routing functions (initialize, interrupt, set_model, …).
// usage: NODE_PATH=<dir with acorn@8> node ast-replay.cjs <unpacked-dir>   (<unpacked-dir> from ../unpack.sh)
const { readChunks, selectFunction } = require("../bundle.cjs");
const root = process.argv[2];
if (!root) {
  console.error("usage: node ast-replay.cjs <unpacked-dir>");
  process.exit(2);
}
// Require the control dispatcher, launch validation and CLI option declaration.
// Chunk hashes and minified names are not part of the behavior under test.
const targets = [
  [
    "control dispatcher",
    [
      'request.subtype==="set_model"',
      "apply_flag_settings",
      "appendSubagentSystemPrompt",
    ],
  ],
  [
    "launch validation",
    ["--sdk-url requires both", "permissionPrompts", "await-initialize"],
  ],
  [
    "CLI options",
    ["--permission-prompts <target>", "--system-prompt-snapshot <on|off>"],
  ],
];
const chunks = readChunks(root);
for (const [label, terms] of targets) {
  const { file, node, text: body } = selectFunction(chunks, terms);
  console.log(
    `${label}: ${file}:${node.id.name} bytes=${node.start}-${node.end}`,
  );
  for (const term of terms) {
    const at = body.indexOf(term);
    console.log(body.slice(Math.max(0, at - 180), at + 600));
  }
}
