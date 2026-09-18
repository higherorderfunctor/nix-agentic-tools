#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

project=/home/caubut/Documents/projects/effect-tui
export EFFECT_TUI_PYTHONPATH="$project/packages/strictdoc-adapter/src"
git -C "$project" rev-parse HEAD
bun --version
bun - "$project/packages/strictdoc-napi" <<'JS'
const bridge = require(process.argv[2]);
const health = JSON.parse(bridge.invokePythonJson(JSON.stringify({protocolVersion: 1, operation: "health"})));
if (health.backend !== "unconfigured" || health.capabilities.join() !== "health") throw new Error("unexpected health response");
console.log(JSON.stringify({health}));
try {
  bridge.invokePythonJson(JSON.stringify({protocolVersion: 1, operation: "board.query"}));
  throw new Error("negative control unexpectedly accepted");
} catch (error) {
  if (!error.message.includes("unsupported bridge operation")) throw error;
  console.log(JSON.stringify({error: error.message}));
}
JS
