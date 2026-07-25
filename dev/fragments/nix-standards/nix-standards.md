### Nix

All home-manager module options must use explicit NixOS module types.
Never use `types.anything` where a specific type is known. Overlay
packages pin `rev` + `hash` inline in their `.nix` files — never
use external source generators. Dependency hashes (`pnpmDeps`,
`vendorHash`, `cargoHash`) are also inline. Per-platform binary
packages store versions and hashes in a `<name>-sources.json` sidecar
managed by `mkUpdateScript`.

### Shell Wrappers: Absolute Paths Required

> **Last verified:** 2026-07-25 (commit pending — records the
> enforcing check, its three command-start anchors, and the
> suppression marker). If you add a new `writeShellScript`,
> `writeShellScriptBin`, or inline shell snippet in any `.nix`
> file and this section isn't consulted, stop and read it.

**Every command in generated shell wrapper scripts MUST use an
absolute Nix store path.** Never use bare command names like `cat`,
`mkdir`, `cp`, `mv`, `rm`, `chmod`, `mktemp`, `tr`, `head`,
`curl`, `grep`, `sed`, `wc`, `basename`, `dirname`, `readlink`,
or `uname`.

Use `${pkgs.coreutils}/bin/<cmd>` (or the appropriate package)
for every external command. Bash builtins (`echo`, `printf`,
`test`, `[`, `export`, `set`, `exec`, `read`, `if`, `while`)
are fine — they don't need PATH.

**Why:** Claude Code's MCP `env` field **replaces** the process
environment entirely rather than merging with the parent. When a
wrapper script is spawned with `env: {"PYTHONPATH": ""}`, the
process has no PATH. Bare `cat` becomes `command not found`,
credentials fail silently, and the server starts without auth.
This caused github-mcp and kagi-mcp to fail at session startup
for weeks before root-causing.

**Contexts where this matters most (high risk):**

- `writeShellScript` wrappers used as MCP server commands
- Any script that reads secrets (`cat <file>`, credential helpers)
- Wrappers spawned by external tools (Claude Code, Copilot, IDE)

**Contexts where it's defensive but still required:**

- HM activation scripts (`home.activation.*`) — run with PATH
  from the activation environment, but should still be explicit
- `writeShellApplication` — gets `runtimeInputs` which provides
  PATH, but the scripts it generates should still prefer explicit
  paths for commands not in `runtimeInputs`
- `installPhase` / `buildPhase` — run inside `stdenv` with full
  PATH from build inputs; absolute paths optional but acceptable

**Enforcement:** `checks/bare-commands.nix` (part of
`nix flake check`) scans `lib/`, `packages/*/lib/`, and the single
file `overlays/lib.nix` for a bare command in any of four
command-start contexts: `$(cmd`, line start, after a `|`, and
after an `&&`. Anchoring only at line start (the original form)
missed three of those four, so a file could look covered while
most real defect shapes walked through.

Because the scan is per-line and the wrapper-versus-build-phase
distinction is a property of the CALLER, a legitimately bare
command in build-context code inside a scanned file is suppressed
with a `# bare-commands: ok` comment **on that same line** — never
by rewriting correct code. `overlays/lib.nix` is the mixed case:
`mkUpdateScript` / `mkGitRevUpdateScript` emit real wrappers,
while `mkClaudeExtract` / `mkKiroExtract` / `mkMcpSmokeTest` emit
build-script bodies.

**Pattern:**

```nix
mkSecretsWrapper = { pkgs, ... }:
  pkgs.writeShellScript "my-wrapper" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    MY_TOKEN="$(${pkgs.coreutils}/bin/cat "/run/secrets/token")"
    export MY_TOKEN
    exec "${lib.getExe package}" "$@"
  '';
```

**Anti-pattern (NEVER do this):**

```nix
pkgs.writeShellScript "my-wrapper" ''
    MY_TOKEN="$(cat "/run/secrets/token")"  # BROKEN: no PATH
    export MY_TOKEN
    exec "${lib.getExe package}" "$@"
  '';
```

### Never Modify Nix Store Paths

**Never `chmod`, `sed`, `cp --remove-destination`, or otherwise
modify files under `/nix/store/`.** Store paths are immutable by
design. If a generated file needs formatting or post-processing,
do it on the working tree copy, not the store original.

**Pattern (generation tasks):**

```bash
src=$(nix build .#my-output --no-link --print-out-paths)
cp -f "$src/file.md" ./output/file.md   # copy to working tree
treefmt ./output/file.md                 # format the copy
```

**Anti-pattern:**

```bash
src=$(nix build .#my-output --no-link --print-out-paths)
chmod u+w "$src/file.md"  # NEVER: modifies store path
prettier --write "$src/file.md"
cp "$src/file.md" ./output/
```

If the output needs to be formatted, either:

1. Format inside the nix derivation (add formatter to build inputs)
2. Format the working tree copy after `cp`

**Destinations may themselves be store symlinks.** Anything declared in
devenv's `files.*` exists in the working tree as a symlink _into_ the
store, so a bare `cp` onto it either follows the link and tries to write
to the read-only original, or — when the generated content is unchanged
and the link already resolves to the source — aborts with `are the same
file`, which is fatal under `errexit`. Always unlink the destination
first. Use `rm -f`, never `cp --remove-destination`, which is banned
above; either way only the working-tree entry is removed, never anything
under `/nix/store`.

`dev/tasks/generate.nix` has two writers, and new code should reuse one
rather than open-coding `cp`:

- `sync_file` / `sync_dir` — for the generated instruction files. Skips
  the write entirely when `cmp` says the content is unchanged (no mtime
  churn on every shell entry), writes through `mktemp` + `mv` so a
  concurrent reader never sees a partial file, and prunes generated
  files whose fragment was renamed away.
- `copy_out` — the simple unlink-then-copy, for one-shot outputs.

Both `chmod` the result: store files are `0444` and the copy inherits
that, which otherwise leaves a read-only file in the tree.

One trap worth naming: **`cmp` ships in `diffutils`, not `coreutils`.**
Interpolating `${pkgs.coreutils}/bin/cmp` yields a path that does not
exist, and because the call sits in an `if` condition a missing binary
is merely a false branch — `errexit` never fires, and every file is
rewritten on every entry instead of being skipped. Silent, and only
visible as churn.

### overrideAttrs: Preserve passthru

When using `overrideAttrs` on nixpkgs packages, **merge passthru
instead of replacing it**:

```nix
# CORRECT — preserves overrideModAttrs, updateScript, etc.
pkg.overrideAttrs (_finalAttrs: old: {
  passthru = (old.passthru or {}) // { mcpName = "my-server"; };
})

# WRONG — drops buildGoModule's overrideModAttrs, causes warnings
pkg.overrideAttrs (_finalAttrs: _old: {
  passthru = { mcpName = "my-server"; };
})
```

`buildGoModule`, `buildPythonPackage`, and other builders attach
helpers to `passthru` (e.g., `overrideModAttrs`,
`overridePythonAttrs`). Replacing `passthru` entirely drops these,
triggering evaluation warnings and breaking downstream overrides.

### Flake Source Visibility

Nix flakes only see git-tracked files. `src = ../.` in a
derivation copies only tracked files into the build sandbox —
untracked files do not exist inside the build. This affects any
check or derivation that scans the source tree (e.g., linting,
grep-based checks).

**Implication:** always `git add` new files before running
`nix flake check` or `nix build` that needs to see them. A
flake check that passes locally may simply not be seeing the
file you just created.
