import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";

// Exercise the installed function without executing the CLI or spawning a host
// executable. Every peer variant must retain the synchronous-error fallback.
const root = process.argv[2];
const files = readdirSync(root)
  .filter((name) => name.startsWith("@napi-rs+cli@"))
  .map((name) => join(root, name, "node_modules/@napi-rs/cli/dist/cli.js"));
assert.ok(files.length > 0, "oxlint: no installed @napi-rs/cli peer variants");

for (const file of files) {
  const source = readFileSync(file, "utf8");
  const functions = source.match(
    /^function executeProcessIncarnationCommand\([\s\S]*?^\}/gm,
  );
  assert.equal(functions?.length, 1, `${file}: expected one process probe`);
  for (const scenario of ["throw", "error", "empty", "success"]) {
    let calls = 0;
    const context = {
      execFile(command, args, options, callback) {
        calls++;
        assert.equal(command, "probe");
        assert.equal(args[0], "argument");
        assert.equal(options.timeout, 321);
        if (scenario === "throw") throw new Error("spawn EPERM");
        callback(
          scenario === "error" ? new Error("probe failed") : null,
          scenario === "success" ? "  incarnation\n" : " \n",
        );
      },
      process: { env: {} },
      processIncarnationCommandTimeout: 321,
    };
    const result = vm.runInNewContext(
      `${functions[0]}\nexecuteProcessIncarnationCommand("probe", ["argument"]);`,
      context,
      { timeout: 1000 },
    );
    const deadline = setTimeout(() => {
      console.error(`${file}: ${scenario} process probe did not settle`);
      process.exit(1);
    }, 1000);
    try {
      assert.equal(await result, scenario === "success" ? "incarnation" : null);
      assert.equal(calls, 1, `${file}: ${scenario} skipped the process probe`);
    } finally {
      clearTimeout(deadline);
    }
  }
  console.log(`oxlint: verified process probe fallback in ${file}`);
}
