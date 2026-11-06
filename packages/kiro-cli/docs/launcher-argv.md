# kiro-cli wrapper: the argv contract

<!-- cspell:ignore avante codecompanion cutover -->

> **Last verified:** 2026-11-05 — Kiro CLI 3.0.0 ships one `kiro-cli` binary.
> The wrapper always prepends `--v3` and adds `--agent-engine=v3` to `acp`
> (before an end-of-options `--`, else last) unless the caller passed an
> `--agent-engine`; it injects no trust flag. The 3.0.0 facts below are read
> from the binary and asserted by `kiro-kas-dispatch`; 2.x measurements are
> labelled as such.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 0057d8ed:packages/kiro-cli/docs/launcher-argv.md`.
>
> - A blanket "every claim below is a MEASURED parse result" framing once
>   shipped four wrong claims unqualified. Source each claim individually —
>   measured vs. sourced-to-file — and re-measure rather than reason.
> - The module runs only the v3 engine. There is no engine option and no v2
>   path; a caller who types `--agent-engine=v2` reaches upstream unmodified,
>   which this repo does not test.

## What is injected where

| Flag                | Position                     | Applies to                                        |
| ------------------- | ---------------------------- | ------------------------------------------------- |
| `--v3`              | **prepend**                  | every subcommand + bare, unless already present   |
| `--agent-engine=v3` | **after `acp`**, before `--` | `acp`, when the caller passed no `--agent-engine` |

Both live in `lib/wrapPackage.nix`. Do not "make them consistent": `--v3` is a
launcher-global option, while `--agent-engine` belongs to `acp`.

## `--v3` is launcher-global, so it is prepended

A global option must appear **before** the subcommand, because after it clap
parses against the _subcommand's_ parser (measured on 2.x):

```console
$ kiro-cli mcp list --tui --v3
error: unexpected argument '--tui' found

$ kiro-cli --tui --v3 mcp list
(works)
```

That error does not mean `mcp` rejects the flag; the wrapper once appended it,
which broke `acp`, `mcp`, `agent`, `settings` and `translate` with an error that
reads exactly like "this subcommand doesn't support the flag".

Without `--v3` the bare launch and `chat` follow the `chat.agentEngine` setting
and the binary's upgrade state, which 3.0.0 moves in both directions: the Rust
strings say "you can try V3 any time with kiro-cli --v3", and the TUI offers
"Back to V2: kiro-cli settings chat.agentEngine v2, or kiro-cli --v2 for one
session". The prepend pins v3 per session. It is injected only when absent as an
exact argv token, because a repeated `--v3` aborts ("cannot be used multiple
times"); `kiro-cli chat 'explain --v3'` still gets the real flag.

## `acp` takes its engine from `acp`, not from `--v3`

3.0.0 resolves the `acp` engine from three inputs, in this order (read from the
binary, not from help text):

1. `acp --agent-engine <v1|v2|v3>`. The alias table also accepts `rust` for v2
   and `kas` for v3.
2. The `acp.agentEngine` setting, matched case-insensitively against the same
   aliases. An unrecognized value is logged and ignored.
3. A default. It is **v2** whenever one of `--agent`, `--model`, `--effort`,
   `--trust-all-tools` or `--trust-tools` was given. Otherwise it is v3,
   provided the host's glibc is 2.28 or newer (or `ldd` cannot say). A v3
   default then reads the client's `initialize`, and a client on the binary's
   built-in list of 1080 names runs **v2** instead. The list includes
   `acp-smoke`, `agent-shell`, `avante.nvim`, `codecompanion.nvim`, `Xcode`,
   `vscode-acp`, `windsurf` and the JetBrains `air-plugin*` entries; `zed` and
   `nix-check` are not on it.

Top-level `--v3` and `KIRO_AGENT_ENGINE` are **not inputs**. CI measured, on the
stock binary: `--v3 acp` and `acp` start KAS for `nix-check` and for EOF, but an
`acp-smoke` initialize gets the v2 engine; `acp --agent-engine=v3` starts KAS
for all three. So the wrapper adds `--agent-engine=v3` to `acp` unless an
`--agent-engine` token, in either spelling, is already before `--`. The scan
reads presence only; a caller's own selector, whatever its value, is left to
upstream. The selector goes in front of an end-of-options `--` (a token past it
is a positional) and last when argv has no `--`: `acp --` becomes
`acp --agent-engine=v3 --`. `kiro-usage exec` applies the same rule to a command
named `kiro-cli`, reusing its launcher-global scan to find `acp`.

`kiro-kas-dispatch` asserts both halves: the raw `acp --agent-engine=v3` start
for EOF, `nix-check` and `acp-smoke`, and, through the wrapper, KAS starting for
an `acp-smoke` client.

**Consequence for a consumer:** `kiro-cli acp --model auto` (or `--agent`,
`--effort`, `--trust-tools`, `-a`) fails with upstream's conflict, exit 2:

```console
$ kiro-cli acp --agent-engine=v3 --trust-tools=fs_read
error: the following arguments are not supported with --agent-engine=v3: --trust-tools
```

That is deliberate. Withholding the selector whenever such an option appears
would silently run v2, which is exactly what upstream's own default does, and
would need a hand-curated conflict list that rots every release. The error names
`--agent-engine=v3`, a flag the user never typed.

**Selecting an agent under v3** is a protocol call, not a flag: the client sends
`session/new` with `_meta.kiro.modeId = <agent name>` (or `session/set_mode`
afterwards). An unknown name falls back to the default mode and sends
`_kiro/customAgent/not_found`. The semble `module-semble-kiro-acp` check drives
exactly this through the wrapper.

## Tool trust is `permissions.yaml`, never a flag

The wrapper injects no `--trust-tools`. Under v3 no process hands the list to
KAS:

- `acp-server.js` has no `trustTools`, `trust_tools` or `trustAllTools`; it
  reads tool policy only from `permissions.yaml` / `permissions.json`, layered
  built-in → admin → `~/.kiro/settings/` → `~/.kiro/workspace-roots/<hash>/`
  (the policy loader; `<hash>` is the first 16 hex digits of a SHA-256 over the
  workspace root). It watches a project's `.kiro/settings/permissions.yaml` but
  never loads rules from it.
- The TUI's KAS path keeps only "trust all tools" or "prompt on demand" and
  drops a per-tool list.
- The 3.0.0 bare launch rejects the flag (`unexpected argument '--trust-tools'`,
  exit 2, measured in CI), and `acp --agent-engine=v3` conflicts with it.

`trustedMcpTools` therefore lowers to allow rules merged into
`settings/permissions.yaml` (`mkPermissionRules` in `lib/mkKiro.nix`). **Tool
trust is Home Manager only**: Home Manager merges that file into
`~/.kiro/settings/`. devenv cannot deliver it. Both files KAS reads sit outside
the devenv root, which the files layer refuses, and giving devenv a root of its
own (a `KIRO_HOME`) would hide the user's real Kiro configuration instead of
extending it. So `ai.kiro.cli.trustedMcpTools` and `ai.kiro.permissions` are
declared under the record's `hm.options` and do not exist on devenv: setting
either there is an unknown-option error. The shared
`ai.mcpServers.<name>.toolPolicy` surface still evaluates on devenv and warns
through Kiro's `surfaceSupport` (`mcpServers` gap), naming the tools that keep
Kiro's default.

> **Probing v3 policy:** read the packaged KAS JavaScript at
> `kiro-cli.kas/node_modules/@kiro/agent/dist/server/acp-server.js`. The Rust
> binary spawns this runtime; a plaintext scan of its compressed embedded bytes
> does not enumerate JavaScript policy. TUI remains a separate embedded asset.
>
> **Do NOT generalize that to feature GATING — there the ELF wins, and reading
> only the JS produces exactly the confident wrong answer this note warns
> about.** Measured 2026-07-31 on 2.16.0. `tui.js` gates hidden features on
> `process.env.KIRO_ENABLED_FEATURES` (a JSON array of strings, parsed once into
> a Set), which reads like an env var you can simply set. It is not: the **rust
> chat binary recomputes and OVERWRITES that variable before spawning bun.** The
> parent process held `["workflows"]` and its bun child received `["tangent"]`.
> `KIRO_ROLLOUT_FORCE_INTERNAL=1`, `KIRO_ROLLOUT_FORCE_NIGHTLY=1` and
> `KIRO_INTERNAL=1` do not move it either — `segment: "internal"` resolves off
> the authenticated identity (`lite` is documented as restricted to
> vendor-internal users), not off the environment.

## How the scan decides (`lib/idempotentFlags.nix`)

`gateOnSubcommand` runs `subcommandBlock`, which walks argv left to right and
stops at the first token that is neither an option nor an option's **value**:

- **Value-taking options must be listed.** `launchValueFlags` in
  `wrapPackage.nix` lists the 3.0.0 top-level ones (`--agent`, `--model`,
  `--agent-engine`, `--resume-id` and others), sourced from the binary's
  chat-argument strings and the TUI's launch-flag table. Without the skip,
  `kiro-cli --agent acp` reads as the `acp` subcommand and a bare launch gets
  `--agent-engine=v3`, which its parser rejects. The `--opt=value` form needs no
  entry: one token, handled by the `-*` arm.
- **`--` parks on a sentinel** no gate matches, so gated injection declines
  rather than guessing.

`idempotentFlagBlock` takes an explicit `position` with **no default** — picking
the wrong one is precisely the bug above. `optionPresenceBlock` reports whether
an option occurs before `--` as `--flag` or `--flag=value`, and never reads the
value.

### Package-bound KAS and selected prompt patches

The native package's ordinary `makeWrapper` setup binds `KIRO_KAS_SERVER_PATH`
and `KIRO_KAS_NODE_PATH` for `kiro-cli`. KAS comes from that CLI release's
fetched input, never from the user's unpacked cache. Fresh launches and launches
with an older cache therefore use the same selected store tree. Linux FHS and
direct payloads share them.

Home Manager defaults `ai.kiro.cli.native.settings.app.disableAutoupdates` to
`true` in the global settings file it already owns when `cli.package` is
non-null. With `cli.package = null`, no updater default is added. Set it to
`false` to re-enable checks; the managed launcher also releases the package's
environment guard. An explicit `cli.environmentVariables.KIRO_NO_AUTO_UPDATE`
still wins. Devenv cannot write this global-only setting, so any update policy
there beyond the environment guard comes from the user's global settings.

The package's `kiro-cli` defaults `KIRO_NO_AUTO_UPDATE=1`. On devenv or with the
package alone, set it to `0`, `false`, `off`, `no` (case-insensitive), or empty
to re-enable checks. The guard unsets `KIRO_NO_AUTO_UPDATE` for those values and
sets it to `1` for anything else. The command is a direct last hop to the
binary, so the guard runs once per launch. Any global
`app.disableAutoupdates = true` must also be released. This handles
presence-based consumers too. The binary's exact update-path semantics remain
unverified: isolated `--version` and unauthenticated probes reached only version
output or the authentication prompt. The stub-based
`kiro-autoupdate-wrapper-chain` check runs the command's wrapper without running
Kiro.

3.0.0 also carries a hidden legacy sweep
(`kiro-cli _ cleanup-autocomplete-artifacts`) that removes leftovers of the
bundled pre-3.0 distribution from `~/.local/bin`, shell rc files and desktop
autostart entries, and a standalone cutover that can install into
`~/.local/bin`. The vendor installer runs the sweep explicitly; whether a first
launch of a store-path binary triggers either is not readable from the binary's
strings and is unmeasured. The package adds no guard for them;
`KIRO_NO_AUTO_UPDATE` and `app.disableAutoupdates` stay the only update
controls.

`lib/kas.nix` extracts the complete runtime through `extract/embedded-kas.py`.
The extractor first selects the target CPU slice of a universal Mach-O (the
Darwin release contains two different KAS archives), scans zstd frames, and
requires exactly one KAS tar with the expected server/package layout and WASM
resources. It validates the compressed frame's SHA-256 against the digest
embedded in that slice. Unrelated compressed resources are ignored; corrupt,
ambiguous, unsafe or incomplete KAS archives fail. Archive members and link
targets cannot escape the extraction root. Linux's bundled native libraries and
ripgrep receive ordinary Nix loader fixups. No native CLI byte patch is added.

The dependency graph is release input → selected KAS → native CLI → optional
FHS/configuration wrappers. KAS never depends on the final CLI, so this is
acyclic and requires no evaluation-time extraction. Each configured runtime
references one installed KAS tree, with its full dependencies/resources copied
from the archive. There is no installed pristine tree underneath a patched one.
The native executable still carries upstream's embedded compressed bytes; those
and fetched build inputs are not a second installed runtime. Ordinary
input-addressed builds share identical selections, but do not promise
cross-release deduplication merely because two releases contain equal payloads.

`passthru.withBundlePatches { replace; }` selects the existing tweaks at build
time; `withRolloutFeatures` and `unwrapped` preserve that selection. The factory
uses the same selector on both backends. Every selected exact source must occur
once or the entire build fails before writing patched output. Unselected prompt
bytes remain unchanged. The independent CI drift check requires both supported
anchors in real vendor data on each platform even when a consumer disables them.

All tweaks still default off. Delegate routing supplies `mkDefault true` for
workflow tweaks only on its reached managed workflow CLI; explicit false wins.
The workflow tweaks retain the existing relative file-check guidance and
deletion of vendor worktree ownership/merge guidance. Configurable prompt files,
additional roots and engine-default changes are separate work.

Inherited overrides have deliberate precedence: all-off uses `--set-default` for
the server, preserving a caller's explicit `KIRO_KAS_SERVER_PATH`. Any managed
tweak uses `--set` so another server cannot silently discard it.
`KIRO_KAS_NODE_PATH` always defaults to the packaged Node and still accepts an
explicit caller override. These are fixed package paths, with no launch-time
materializer or cache-selection fallback.

KAS is proprietary release data (`@kiro/agent` declares `AWS-IPL`); no
open-source repository has been established for this payload. Its derivation
names start with `kiro-cli-kas`, selected changes add `-patched`, and both stay
under the existing `kiro-cli` cache exclusion. The native package's full closure
cache exclusion check includes KAS. Neither the package nor its facts are read
at evaluation from a derivation output.

`kiro-kas-extraction` covers discovery/architecture/checksum and unsafe archive
refusals. `kiro-bundle-patch` covers strict selected-anchor refusal and decoded
synthetic JavaScript behavior. `kiro-bundle-patch-drift` checks every vendor
selection, the real native ONNX module, WASM solving, shipped ripgrep, and ACP
initialization. `kiro-kas-dispatch` exercises the real wrapped `kiro-cli`,
CLI/ACP, fresh/stale homes, override precedence and a client on the binary's v2
list, plus the raw `acp --agent-engine=v3` measurement on the stock binary. The
FHS contract check separately inspects the command paths inside the synthesized
root; nested bubblewrap execution is not portable inside a Nix build sandbox.

### `extraPackages` — a PATH prefix, not an FHS rebuild

`ai.kiro.cli.extraPackages` adds one more environment-only injection to the
`kiro-cli` wrapper. Its store-backed `bin` directories are prepended after
ordinary and secret environment exports, so an explicit
`ai.kiro.cli.environmentVariables.PATH` becomes the base and the requested
packages are first at that wrapper boundary. With no explicit PATH, the caller's
inherited value remains after the prefix. Setting the Kiro-specific PATH entry
to null suppresses a root `ai.environmentVariables.PATH`, restoring the ambient
base before `extraPackages` is prepended.

That is not final override precedence on Linux. The upstream FHS `/init` then
sources `/etc/profile`, which puts `/run/wrappers/bin:/usr/bin:/usr/sbin` ahead
of the inherited entries. The requested package remains visible, but a
same-named command already in the synthesized root wins. This option is for
supplying missing tools; Darwin has no later FHS reordering.

The empty list is inert. A non-empty list does not alter argv, and
`packages/kiro-cli/checks/kiro-wrapper-argv.nix` runs the launcher to assert the
prefix and inherited tail together.

On Linux this crosses the upstream FHS visibility boundary because `/nix` is
mounted and PATH is preserved; it does not merge packages into the synthesized
root. See [`fhs-sandbox.md`](fhs-sandbox.md) for why that distinction matters.

## Linux FHS layer

The public Linux package is this repo's own `buildFHSEnv` around the pinned
payload: `$out/bin/kiro-cli` is the bubblewrap launcher and `/init` execs the
payload's `kiro-cli` directly, so only `bin/kiro-cli` is shipped. The payload's
`wrapProgram` shim lives on `passthru.unwrapped`. The module's launcher sits
outside the FHS package, and argv and environment pass through every layer. See
[`fhs-sandbox.md`](fhs-sandbox.md) for the bind rule, shadowed set and loader
trap. Darwin builds no FHS layer.

`ai.kiro.cli.useFhsSandbox = false` makes the launcher exec `passthru.unwrapped`
directly. That is an explicit compatibility tradeoff; see
[`fhs-sandbox.md`](fhs-sandbox.md) for the extracted-`bun` risk.

## Rollout features

The rollout manifest is embedded in the binary and its names and vendor state
are extracted into the aggregate facts under `packages/kiro-cli/extracted/`.
`ai.kiro.cli.features.<name>.enable` exposes those names; restricted entries are
enabled by a length-preserving patch through `passthru.withRolloutFeatures`, and
entries already available to every user preserve the stock package. Patch
feasibility comes from `rolloutPatchability.<name>.patchable`. Enabling an
unpatchable feature fails at evaluation and names the extracted flag.

Workflows are GA since 2.26.0 and need no binary patch. `cli.workflows.enable`
still requires the global `chat.enableWorkflows` setting; Home Manager implies
it and devenv warns when it is absent. `codeToSpec`, `backgroundExecution`,
`kvim` and `sandbox` are friendly switches over restricted rollout names, with
client-setting and launch prerequisites described in
[`workflow-gating.md`](workflow-gating.md). Raw feature switches change
availability only. Typed `cli.native.settings.chat.keybindings` declarations
follow the extracted registry; background execution can be rebound with
`moveToBackground` in the global settings.

## Re-measuring on a version bump

Run against the **unwrapped** binary — a bare `PATH` lookup finds the wrapper,
which is the thing under test. One binary serves both platforms.

```bash
K=$(nix build --no-link --print-out-paths .#ciPackages.x86_64-linux.kiro-cli.unwrapped); KB="$K/bin/kiro-cli"

# 1. globals still parse BEFORE a subcommand, and still fail after it
"$KB" --v3 whoami >/dev/null && echo "prepend ok"
"$KB" whoami --v3 2>&1 | grep -q "unexpected argument" && echo "append still fails"

# 2. the acp engine resolution: rerun kiro-kas-dispatch and read its MEASURE
#    rows; a listed client that starts KAS under plain `acp` means upstream's
#    default changed, and one that does not under `acp --agent-engine=v3`
#    breaks the wrapper's selector.

# 3. the v3 conflict set on acp: "not supported with --agent-engine=v3: <opt>"
#    (exit 2) means conflict; the empty baseline must not conflict.
for opt in "" "--agent x" "--model auto" "--effort low" "--trust-tools=x" "-a"; do
  out=$("$KB" acp --agent-engine v3 $opt </dev/null 2>&1)
  echo "[$opt] $? ${out%%$'\n'*}"
done
```

Read `--help-all` for the launcher's own options (that Options block is what
"global" means here) and each subcommand's `--help` for its own. Confirm with a
parse probe rather than trusting help text — use an argument that fails
validation LATE, so "unexpected argument" versus "invalid value" distinguishes a
parse rejection from an accepted flag.

## Tests

- `packages/kiro-cli/checks/kiro-wrapper-argv.nix` — the real wrapper against a
  stub package that prints its argv. Covers which SIDE of the subcommand each
  flag lands on, the value-flag skip, `--`, idempotence of `--v3`, the
  presence-only `acp` selector, the absence of `--trust-tools`, and the env/PATH
  export paths.
- `packages/kiro-cli/checks/kas-dispatch.py` (`kiro-kas-dispatch`) — the real
  3.0.0 binary through the wrapper, and the raw `acp --agent-engine=v3`
  measurement.
- `packages/kiro-cli/checks/kiro-fhs-contract.nix` — structurally inspects the
  realized upstream Linux command wrapper, shared launcher, init, dispatcher and
  profile, without executing bubblewrap inside the Nix build sandbox.
- `packages/kiro-cli/checks/module-eval.nix` — the generated bash shape, the
  removed `ai.kiro.cli.v3` option, and the Home Manager `permissions.yaml`
  (`module-kiro-hm-permissions-trusted-tools`).
- `checks/ai-warnings/default.nix` (`ai-warnings-kiro-tool-trust`) — the trust
  and permissions options exist on Home Manager only, and devenv warns on MCP
  `toolPolicy`.

## Do not break the exec line

The wrapper ends with `exec -a "$0" <realBin> "$@"`. Keep that shape: recovering
the real binary by reading the line back out of the generated wrapper is how you
probe the unwrapped CLI at all (see the re-measure recipe above), and
`packages/kiro-cli/checks/kiro-wrapper-argv.nix` asserts on it.

An earlier revision credited "probe scripts under `docs/plans/`" with depending
on this. Nothing there does — `grep -rl 'exec -a' docs/plans` is empty — so the
check is the only thing pinning it.

## Optional usage capture

`cli.usageTracking.enable` is another managed-wrapper reason on both backends.
Before the launcher executes its real binary, it requires the private usage
service's CA and loopback listener, rejects inherited proxy conflicts, and
exports the local HTTP(S) proxy and Node extra CA only for Kiro's process tree.
These exports remain outside the FHS package and are inherited across it. The
same wrapper package installs `kiro-usage` for explicit indexing, session
queries, and unpacking. Its `exec` command reuses the same readiness and
environment preparation for a PATH-selected command and composes with the
managed wrapper. A named `kiro-cli` command receives an idempotent `--v3`;
generic commands keep their arguments. See
[usage-tracking.md](usage-tracking.md) for options, service lifecycle, scope,
and limitations.
