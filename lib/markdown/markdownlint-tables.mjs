// markdownlint's MD056 alone, over exactly the paths given: the markdownlint
// half of the table-cell check in ./table-cells.nix.
//
// It calls the markdownlint LIBRARY instead of the markdownlint-cli2 command
// because the command reads configuration from the tree it checks. A
// `.markdownlint*` or `.markdownlint-cli2.*` file in the working directory, or
// in a directory between it and a checked file, can turn MD056 off, ignore
// every file, or turn on unrelated rules, and `--config` does not stop it. The
// library reads no configuration file: its only rule set is the one passed
// below. It also takes paths literally, where the command treats each one as a
// glob and reports "0 issues in 0 files" when a literal path does not match.
//
// Configuration INSIDE a checked file is honored, like any lint
// suppression: `<!-- markdownlint-disable MD056 -->` lets an author suppress
// MD056 for their own file. Only MD056 results are counted and printed, so a
// `markdownlint-configure-file` comment that turns other rules on cannot fail
// a file for them, and neither can a later markdownlint that reports anything
// else anyway.
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const files = process.argv.slice(2);
const entry = createRequire("@cli2@").resolve(
  "markdownlint-cli2/markdownlint/promise",
);
const { lint } = await import(pathToFileURL(entry).href);
const results = await lint({
  config: { default: false, MD056: true },
  files,
});

let findings = 0;
for (const file of files) {
  for (const error of results[file] ?? []) {
    if (error.ruleNames.includes("MD056")) {
      findings += 1;
      console.error(
        `${file}:${error.lineNumber} MD056 ${error.ruleDescription}`,
      );
    }
  }
}
process.exit(findings === 0 ? 0 : 1);
