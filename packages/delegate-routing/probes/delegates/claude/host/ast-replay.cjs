const fs = require("fs");
// codex:H — prints the host-control routing functions (initialize, interrupt, set_model, …).
// usage: NODE_PATH=<dir with acorn@8> node ast-replay.cjs <unpacked-dir>   (<unpacked-dir> from ../unpack.sh)
const acorn = require("acorn");
const root = process.argv[2];
if (!root) {
  console.error("usage: node ast-replay.cjs <unpacked-dir>");
  process.exit(2);
}
const targets = [
  ["chunk-8h3wkqrn.js", ["yd", "llo", "od"]],
  ["chunk-40wfk18e.js", ["yrt"]],
  ["chunk-ya33qr7x.js", ["gr"]],
];
for (const [file, names] of targets) {
  const source = fs.readFileSync(`${root}/${file}`, "utf8");
  const ast = acorn.parse(source, {
    ecmaVersion: "latest",
    sourceType: "module",
  });
  for (const node of ast.body) {
    if (node.type !== "FunctionDeclaration" || !names.includes(node.id.name))
      continue;
    const body = source.slice(node.start, node.end);
    const matches = [
      "initialize",
      "interrupt",
      "set_model",
      "set_permission_mode",
      "permissionPrompts",
      "sdk-url",
      "await-initialize",
    ].filter((s) => body.includes(s));
    if (matches.length) {
      console.log(
        `${file}:${node.id.name} bytes=${node.start}-${node.end} matches=${matches.join(",")}`,
      );
      console.log(body.slice(0, 1700));
      console.log();
    }
  }
}
