## claude-code Wrapper Chain

> **Last verified:** 2026-04-07 (commit a56b8d4). If you touch
> `packages/ai-clis/claude-code.nix`, the buddy activation script,
> or the HM plugin wrapper integration and this fragment isn't
> updated in the same commit, stop and fix it.

The `claude` binary a user invokes goes through **two wrappers**
before reaching the actual JavaScript CLI. Debugging any runtime
oddity (missing env vars, wrong cli.js being run, broken
`--plugin-dir`) requires knowing the full chain.

### The chain

```
claude             (HM plugin wrapper, from nixpkgs claude-code module)
  → .claude-wrapped  (our Bun runtime wrapper, added by claude-code.nix)
    → bun run cli.js  (the actual CLI under Bun runtime)
```

1. **HM plugin wrapper** (`$out/bin/claude`): a short bash script
   produced by nixpkgs' `programs.claude-code` module. It execs
   `.claude-wrapped` with a `--plugin-dir <store-path>` argument
   pointing at a generated plugin store path.
2. **Our Bun wrapper** (`$out/bin/.claude-wrapped`): a bash script
   generated inside `packages/ai-clis/claude-code.nix` by the
   `symlinkJoin` postBuild. Always installed, whether or not a
   buddy is configured. Its job is to pick which `cli.js` to run
   (user state or store) and exec it under Bun.
3. **Bun runtime** (`${bun}/bin/bun run $CLI`): the actual JS
   executor. Under Bun, `typeof Bun !== "undefined"` in the
   process, which claude-code's buddy hashing detects and uses
   to route to wyhash (instead of fnv1a on Node).

### Why Bun

The any-buddy worker computes a 15-char salt that hashes, together
with the user's UUID, to the desired buddy traits. Claude-code's
runtime buddy hash function is `wyhash` when `typeof Bun !== "u"`
and `fnv1a` otherwise. If the salt is computed under wyhash and
the runtime uses fnv1a (or vice versa), the buddy you asked for
is NOT what hatches. Running under `bun run` ensures both the
worker AND the runtime use wyhash. This is why the Bun wrapper
is installed unconditionally, even when no buddy is configured —
the wrapper is cheap insurance against accidental Node execution
breaking a future buddy config.

Bun adds ~95 MB to the runtime closure. Acceptable trade-off for
the hash-consistency guarantee.

### passthru.baseClaudeCode

`packages/ai-clis/claude-code.nix` builds a `symlinkJoin` around
the base nixpkgs `claude-code` derivation, replacing `bin/claude`
with the Bun wrapper. The wrapped join is `pkgs.claude-code` (what
consumers get). The unwrapped base is exposed as
`pkgs.claude-code.passthru.baseClaudeCode`.

The buddy activation script in `modules/claude-code-buddy/` needs
to find the store's actual `cli.js` at the nixpkgs-managed path
(under `lib/node_modules/@anthropic-ai/claude-code/cli.js`), not
the wrapped binary. It does:

```nix
baseClaudeCode =
  config.programs.claude-code.package.passthru.baseClaudeCode
  or config.programs.claude-code.package;
storeLib = "${baseClaudeCode}/lib/node_modules/@anthropic-ai/claude-code";
```

The `or` fallback handles the case where a user swaps out
`programs.claude-code.package` with a non-nix-agentic-tools
package that doesn't have this passthru. The activation script
still works — it just points at whatever `package` the HM config
is using and hopes the `lib/node_modules/...` layout exists.

### cli.js resolution in the wrapper

The Bun wrapper has two code paths:

```bash
USER_LIB="${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy/lib"
if [ -f "$USER_LIB/cli.js" ]; then
  CLI="$USER_LIB/cli.js"          # buddy state copy (patched)
else
  CLI="$STORE_LIB/cli.js"         # store fallback (unpatched)
fi
exec ${bun}/bin/bun run "$CLI" "$@"
```

When the buddy activation script has run at least once, a writable
`cli.js` exists at `$XDG_STATE_HOME/claude-code-buddy/lib/cli.js`
with the salt patched into it. The wrapper picks that up. Before
first activation (or if the state dir is wiped), the wrapper falls
back to the store cli.js, which runs claude-code normally without
the custom buddy. No breakage either way — this is the "always
wrapped, gracefully degrades" design.

### Symptoms and what they mean

- **`claude` launches but the buddy is wrong**: activation script
  probably didn't run (check `$XDG_STATE_HOME/claude-code-buddy/fingerprint`
  exists) OR the salt the worker computed doesn't match the
  claude-code runtime's hash function (verify both are under Bun)
- **"Claude Code has switched from npm to native installer"**
  snackbar warning every launch: the `Zj()` check in cli.js looks
  for `Bun.embeddedFiles.length > 0`, which is true only for
  `bun build --compile` single-execs. We run a plain cli.js under
  `bun run` so embeddedFiles is empty. Suppressible via
  `DISABLE_INSTALLATION_CHECKS=1` env var — see the backlog.
- **`cat $(which claude)` shows the HM plugin wrapper, not our
  Bun wrapper**: expected. The HM plugin wrapper execs `.claude-wrapped`
  which IS our wrapper. Inspect `bin/.claude-wrapped` in the
  claude-code store path to see the Bun wrapper source.

### Not here

Buddy activation lifecycle (fingerprint semantics, salt search,
cli.js patching, companion reset): see
`buddy-activation` fragment in this same directory.
