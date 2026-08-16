## Per-runtime pool capability and nullable overrides

> **Last verified:** 2026-08-15 (commit pending — distinguishes scalar
> null-as-inherit from keyed-pool null tombstones and removes the retired
> collision-assertion rationale for internal process defaults). Prior:
> 2026-08-15 (commit pending — package guidance now uses keyed per-runtime
> rules; the pool census no longer includes the retired instructions list).
> Prior: 2026-08-15 (commit pending — `supportedPools` now gates all normalized
> pool declarations and fanout, while the new normalized `settings` surface is
> deliberately present on every runtime and resolves nullable fields per runtime
> through the same override rule as `ai.shell`). Prior: 2026-08-14 (commit
> pending — the escape hatch at the end of the Copilot section was half-wrong:
> at 1.0.80 the plain `@github/copilot` npm tarball is a 24K loader shim, not
> readable JS. The readable app code is in the per-platform dep — and, better,
> the SEA self-extracts a byte-identical copy on first run, so no download is
> needed at all. The Copilot `ai.shell` gap itself is UNCHANGED and still open).
> Prior: 2026-08-10 (commit pending — first landing of `ai.shell`. If you add
> another nullable-scalar `ai.*` option, change which runtimes consume this one,
> or touch `resolveOverride`, update this fragment in the same commit.)

### One record is the capability source

Every `mkAiApp` record declares the normalized pools its runtime exposes in
`supportedPools`. `mkBackendTransform.nix` reads that build-time list in four
places:

- only supported per-runtime pool options are declared;
- only supported pools participate in shared/per-runtime merging;
- only supported root pools reach the backend callback; and
- `shell` resolution runs only when `shell` is in the list.

An unsupported per-runtime write is therefore an "option does not exist" eval
error. An unsupported ROOT value is different: root `ai.*` is the portable
surface, so its fanout degrades to the pool's neutral value for that runtime.
For example, `ai.kimchi.rules` does not exist, while root `ai.rules` remains
valid and simply does not reach Kimchi.

The list is read off the RECORD, keeping it a build-time parameter in the same
category as `backend`. It forces neither `config` nor the factory's `pkgs`, so
it cannot reintroduce the `_module.args` recursion documented against
`proxyIsSupported`.

A same-named native option does not imply normalized-pool support.
Runtime-shaped passthrough now lives under `nativeSettings`, independently of
the capability list. Normalized `settings` is the deliberate uniform exception:
all five runtimes list it so the same closed schema is available at every
runtime scope, even when a particular field currently has a lossless native
lowering only for a subset such as Claude and Codex.

### `ai.shell` deliberately uses null-as-inherit

Every keyed normalized pool uses per-runtime replacement, with null meaning
delete the inherited entry. `ai.shell` and each normalized `ai.settings` field
are structurally different: they are scalar defaults, so null means inherit.
`ai.claude.shell` is not an independently named entry competing with `ai.shell`;
it is the same knob at a narrower scope.

Resolution lives in `lib/ai/ai-common.nix:resolveOverride` (non-null per-CLI
wins, `null` inherits the root, `null` at both levels means "not configured").
Do not inline the `if` at call sites; the contrast with keyed-pool tombstones is
the thing worth keeping easy to grep for.

Normalized settings use that helper per field. For example,
`ai.claude.settings.reasoningEffort = "low"` overrides a root
`ai.settings.reasoningEffort = "high"` for Claude only; Codex still inherits
`"high"`. A null runtime value inherits the root. This is distinct from
`nativeSettings`, which carries runtime-shaped passthrough and typed-native keys
and participates in native option-priority rules only after normalized values
have been resolved.

### Shell is one capability entry

`mkBackendTransform.nix` declares `ai.<name>.shell` and computes `resolvedShell`
only when `shell` appears in the app record's `supportedPools`. There is no
sibling shell-specific capability flag.

| runtime | knob                       | delivery                               |
| ------- | -------------------------- | -------------------------------------- |
| Claude  | `CLAUDE_CODE_SHELL`        | `nativeSettings.env` → `settings.json` |
| Codex   | `SHELL` (own process env)  | launcher wrapper `--set`               |
| Kiro    | `SHELL` (own process env)  | launcher wrapper `export`              |
| Copilot | **unknown — verified gap** | excluded                               |
| Kimchi  | unassessed                 | excluded                               |

Four runtimes were asked for; five go through `mkAiApp`. Kimchi is easy to miss
because the issue that requested this never mentioned it.

### NEVER write the shell environment

**This repo does not set Home Manager session variables or devenv `env` entries.
Anything a runtime needs in its process environment goes into that runtime's
launcher wrapper.** Children inherit across `fork`/`exec`, so git or any other
command a harness spawns still sees the value — while the developer's own shell,
and every other process in it, does not.

There is no exception, and the rule is the operator's: devenv/Nix is the only
config path, so a shell-level escape hatch buys nothing and costs scope.

Enforcement is by eye. `rg '^\s*env\s*=|^\s*env\.[A-Z_]+\s*=|sessionVariables'`
over `packages/ lib/ devshell/` should return only `mkOption` declarations. Two
other `env` shapes are legitimate and will show up in a careless grep: an MCP
server's `env` field (`lib/mcp.nix`, `mcpSecrets.nix`) is the MCP protocol's
per-server environment and reaches the server process, not your shell; and
option declarations are not writes.

This was not always true — four sites wrote the devenv shell until 2026-08-10,
each with a comment reasoning that devenv "has a native `env` attrset so no
wrapper is required". That was correct about the mechanism and wrong about the
scope, and it went unnoticed because the variables involved (`KIRO_LOG_LEVEL`,
`COPILOT_MODEL`) were harmless to leak. `SHELL` is the one that made it visible,
since it changes what tmux, editors and anything else spawning `$SHELL` will
run.

### The fallback behavior is asymmetric, and that is the whole safety argument

Every runtime here falls back when the configured shell is unusable, but they do
not fall back to the same place — and neither one warns in a way a consumer will
see:

- **Claude silently ignores an unusable `CLAUDE_CODE_SHELL`.** No warning,
  exit 0. Measured twice on 2.1.222 with a nonexistent path. It does **not**
  fall back to `$SHELL` — an explicit `SHELL=/usr/bin/zsh` was ignored and it
  resolved its own bash. So a bad value degrades to a working bash: the hazard
  does not return, but the OPTION silently does nothing.
- **Codex falls back to the PASSWORD-DATABASE shell.** From its own strings
  (`portable_pty::cmdbuilder`):
  `$SHELL -> … which is not executable …, falling back to password db lookup`.
  That is the opposite risk — on a machine whose passwd shell is the one being
  migrated away from, a bad value silently restores it.
- **Kiro uses `process.env.SHELL || "/bin/sh"`.** `||` is an unset-or-empty
  fallback, so an invalid path should fail loudly at spawn instead. Derived from
  the operator semantics, not yet measured.

**This is why the option takes a package, not a path.** A package is guaranteed
to exist in the store at activation and is GC-rooted by the generation that
references it, so the entire "path is wrong, moved, or collected" class is
eliminated by construction rather than by a runtime check that two of these
three runtimes demonstrably do not perform.

### Traps

- **`pkgs.bash` IS `pkgs.bashInteractive`** in this repo's pinned nixpkgs — same
  derivation, identical `drvPath`, `pname = "bash-interactive"`. Choosing
  between them is not a decision. The real distinct package is
  **`pkgs.bashNonInteractive`**. Any test asserting "the override changed the
  value" must use that one, or it passes vacuously against two names for one
  store path.
- **`--set`, never `--set-default`.** This repo reserves `--set-default` for
  polite defaults a user may override (`TERM`, `GH_TELEMETRY`). A configured
  shell must beat the ambient environment. For Codex this matters more than it
  looks, because "unset" is not neutral — it lands on the passwd shell.
- **Codex had no wrapper before this option.**
  `packages/chatgpt-codex/lib/wrapPackage.nix` is new; the wrapper is skipped
  entirely when its env set is empty, so a Codex with nothing to deliver still
  gets the bare upstream path.
- **On devenv that empty case is unreachable in practice.** devenv has no
  `programs.git`, so the sandbox-safe Git SSH default (`gitSshConfigWorkaround`,
  on by default) lands in Codex's `environmentVariables` — which means enabling
  Codex on devenv ALWAYS builds a wrapper, while Home Manager ships it bare.
  That divergence is asserted by `module-codex-enabled-installs-package`; if you
  are wondering why the two backends install different store paths, this is why,
  and it is intended.
- **`ai.environmentVariables` now reaches Codex too.** Codex gained an
  `environmentVariables` option when its wrapper was built, so the root pool
  fans out to Codex, Copilot, Kimchi and Kiro. Claude is still outside it — it
  has no wrapper here and `nativeSettings.env` is its native equivalent.
- **One precedence rule, everywhere: module defaults merge UNDER the consumer's
  `environmentVariables`, so an explicit entry wins.** Codex briefly did the
  reverse — typed option last, on the reasoning that the typed surface is more
  specific. Defensible alone, wrong in aggregate: Claude and Kiro both let the
  explicit entry win, so the identical two-key config resolved differently
  depending on which runtime the consumer named. Guarded by
  `module-ai-shell-explicit-env-beats-typed-{codex,kiro}`; change them together
  or not at all.
- **Always-on process defaults do not write hidden normalized-pool entries.**
  `ai.<cli>.environmentVariables` is the consumer's replacement/negation
  surface, and definition provenance treats package claims there as owned API.
  Internal defaults such as the sandbox-safe SSH command therefore ride
  `ai._sandboxSafeSshCommand` / the `resolvedShell` callback argument and merge
  under consumer values at the wrapper call site. Opt-in packages may publish
  documented per-runtime pool entries; two packages still cannot own the same
  key and scope. See `collision-semantics.md`.

- **`shell_environment_policy` is not the Codex knob.** It filters what SPAWNED
  commands inherit; writing the shell there configures the children, not Codex.
- **`KIRO_CHAT_SHELL` is a dead end.** It exists only in Kiro's Rust binary, is
  absent from the v3 JS bundle, and the wrapper forces `--v3`.

### Why Copilot is a gap rather than a TODO someone can just close

Copilot ships as a **Node SEA** whose application code is a compressed blob, so
plaintext scanning of the 177 MB executable cannot answer the question. A scan
returns a couple of `SHELL` hits, but a **positive control fails** —
`githubcopilot`, `tool_use` and `gpt-` all return zero — which proves the app
code is not searchable and makes any negative result meaningless rather than
informative. The only readable hits are vendored Node internals
(`normalizeSpawnArguments`, `os.userInfo`), and Node's `shell: true` hardcodes
`/bin/sh` regardless of `$SHELL`.

Run a positive control before trusting ANY negative result against these
single-executable CLIs. Codex, by contrast, is a Rust binary whose string table
IS readable (`codex` = 1030 hits), which is why its mechanism could be settled
the same way.

To close the gap, read the app code — do not re-run a plaintext scan of the SEA.
**The cheapest route is that the SEA self-extracts its payload on first run**,
to `~/.cache/copilot/pkg/<platform>/<version>/`; `app.js` there is ~9 MB of
minified but fully searchable JS, alongside the Rust core `runtime.node` where
discovery actually lives. Measured 2026-08-14 against 1.0.80, with
`copilot-instructions.md`, `no-custom-instructions` and
`No authentication information found` as positive controls — all three hit,
where the same scan of the SEA itself returns zero for every one of them.

Do not reach for the plain `@github/copilot` npm tarball for this: at 1.0.80 it
is a 24K loader shim. The readable JS is in the per-platform optional dep
(`@github/copilot-linux-x64`), and its `app.js` is sha256-identical to the
self-extracted copy — so the self-extract route buys the same bytes with no
download.

### Verifying a change here

```bash
# the option surface, both backends
nix build .#checks.x86_64-linux.options-doc-ai-parity

# semantics: precedence, inertness, exclusions, wrapper contents
nix build .#checks.x86_64-linux.module-ai-shell-per-runtime-overrides-root
nix build .#checks.x86_64-linux.module-ai-shell-codex-hm-wrapper-carries-shell
```

`module-ai-shell-accepted-for-claude` is the **positive control** for the two
exclusion tests. Those assert an eval failure, which a broken harness satisfies
for free; the control runs the identical `tryEval` shape against a supported
runtime and requires success. Delete them as a set or not at all.

The generalized gate has the same paired controls for Kimchi's removed `rules`
and `rulesDir` options: `module-ai-rules{-dir,}-accepted-for-claude` and
`module-ai-rules{-dir,}-excluded-for-kimchi`.
