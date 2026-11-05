# kiro-cli wrapper: the argv contract

<!-- cspell:ignore avante codecompanion cutover -->

> **Last verified:** 2026-11-05 — Kiro CLI 3.0.0 ships one `kiro-cli` binary;
> its wrapper appends `--agent-engine=v3` on `acp` and carries `--trust-tools`,
> gated on the effective engine from `--agent-engine` or `--v3`. `kiro-cli-chat`
> is a temporary package alias. The 3.0.0 argv facts below are asserted by
> `kiro-kas-dispatch`; the `acp` engine resolution order is read from the binary
> and measured by that check's `MEASURE` rows; 2.x measurements are labelled as
> such.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 0057d8ed:packages/kiro-cli/docs/launcher-argv.md`.
>
> - A blanket "every claim below is a MEASURED parse result" framing once
>   shipped four wrong claims unqualified: an audit refuted the `--tui`
>   inertness mechanism, the "on `chat`, v3 accepts all five" claim (false on
>   2.15.2, where `-a` conflicted; 2.24.1 accepts `-a` on `chat`, see the
>   conflict table), the `tui.js` `--trust-tools` auto-answer, and a
>   probe-script reference to files that do not exist. Source each claim
>   individually — measured vs. sourced-to-file — and re-measure rather than
>   reason; do not trust a blanket claim of "measured" again.

## The one thing to know

`--tui` and `--v3` are **launcher-global** options. They are positional: a
global option must appear **before** the subcommand, because after it clap
parses against the _subcommand's_ parser.

```console
$ kiro-cli mcp list --tui --v3
error: unexpected argument '--tui' found

$ kiro-cli --tui --v3 mcp list
(works)
```

**That error does not mean `mcp` rejects `--tui`.** It means the flag was in the
wrong place. This is worth stating flatly because getting it wrong once already
cost a release: the wrapper used to _append_ these flags, which broke `acp`,
`mcp`, `agent`, `settings` and `translate`, and the failure reads exactly like
"this subcommand doesn't support the flag."

So the wrapper **prepends** them. Prepended, every subcommand accepts them.

## `acp` takes its engine from `acp`, not from `--v3`

Since 3.0.0 the release ships one `kiro-cli` binary that runs the chat
implementation itself; nothing dispatches to a separate chat binary through
`PATH`. A top-level `--v3` reaches `chat` and the bare launch, but **not
`acp`**. On 2.x the launcher rewrote `--v3 acp` into `acp --agent-engine v3` for
a separate `kiro-cli-chat` (measured on 2.15.2); that rewrite no longer exists.

3.0.0 resolves the `acp` engine from three inputs, in this order (read from the
binary, not from help text):

1. `acp --agent-engine <v1|v2|v3>`. The binary's alias table also accepts `rust`
   for v2 and `kas` for v3.
2. The `acp.agentEngine` setting, matched case-insensitively against the same
   aliases. An unrecognized value is logged and ignored.
3. A default. It is **v2** whenever one of `--agent`, `--model`, `--effort`,
   `--trust-all-tools` or `--trust-tools` was given (the same five flags the v3
   conflict below names). Otherwise it is v3, provided the host's glibc is 2.28
   or newer (or `ldd` cannot say). A v3 default that did not come from the flag
   or the setting then reads the client's `initialize`, and a client on the
   binary's built-in list of 1080 names runs **v2** instead. The list includes
   `acp-smoke`, `agent-shell`, `avante.nvim`, `codecompanion.nvim`, `Xcode`,
   `vscode-acp`, `windsurf` and the JetBrains `air-plugin*` entries; `zed` and
   `nix-check` are not on it.

Top-level `--v3` and `KIRO_AGENT_ENGINE` are **not inputs** to that order. The
help text for `--agent-engine` ("v2 when neither is set") is stale. The evidence
is a CI run of `--v3 acp --trust-tools=fs_read`: it exited 0 with empty stderr
and never started KAS, because `--trust-tools` made the default v2, and the v2
engine answered the initialize itself. The host exports `KIRO_AGENT_ENGINE` to
the TUI child process; it is not an `acp` input, and the matrix below carries a
`KIRO_AGENT_ENGINE=v3 acp` row to show it.

So the wrapper cannot rely on `--v3` for `acp`. With `ai.kiro.cli.v3 = true` it
appends `--agent-engine=v3` on `acp` when the caller gave no `--agent-engine`
(`acpEngineBlock` in `lib/wrapPackage.nix`). That keeps every client on v3,
including listed ones, and keeps usage tracking's v3 assumption true. Two
consequences:

- Under v3, `kiro-cli acp --model/--agent/--effort/-a` now fails with upstream's
  conflict error (exit 2) where on 3.0.0 without the selector it silently ran
  v2. This is the same trade as on 2.x, under
  [the v3 + `acp` conflict](#the-v3--acp-conflict).
- The trust gate must withhold `--trust-tools` on `acp` whenever the engine is
  v3. The gate is also load-bearing for another reason: appending
  `--trust-tools` to an `acp` with no selector would flip upstream's default to
  v2. The selector is added first, so the gate sees it.

An explicit `--agent-engine=v3` makes `--trust-tools` conflict on `acp`:

```console
$ kiro-cli acp --agent-engine=v3 --trust-tools=fs_read
error: the following arguments are not supported with --agent-engine=v3: --trust-tools
```

On 2.x the same error appeared for `--v3 acp --trust-tools=fs_read`, and it
named `--agent-engine=v3` although the user never typed it. On 3.0.0 `--v3` does
not reach that check. KAS takes no trust flag, so withholding the grant drops
nothing.

**A caller's explicit `--agent-engine` wins.** The wrapper appends nothing when
one is present, in either spelling, so `kiro-cli acp --agent-engine=v2` runs v2
and gets the grant. A caller's `--v3 acp --agent-engine=v2` runs v2 as well. The
trust gate mirrors that order and implements no other precedence.

`kiro-kas-dispatch` prints a `MEASURE` row for every cell of this matrix on the
3.0.0 stock binary (no managed argv injection), each with three inputs (EOF, an
`initialize` from `nix-check`, one from `acp-smoke`), before it asserts
anything. The table is what the reading above predicts; a measured row that
disagrees is a finding, not a flake:

| argv                                             | Expected                                          |
| ------------------------------------------------ | ------------------------------------------------- |
| `--v3 acp` and `acp` (identical)                 | KAS starts, except for a listed client (v2 reply) |
| `acp --agent-engine=v3`                          | KAS starts for every client                       |
| `--v3 acp --trust-tools` and `acp --trust-tools` | v2 engine, KAS not started, exit 0                |
| `acp --agent-engine=v3 --trust-tools`            | exit 2, conflict, KAS not started                 |
| `KIRO_AGENT_ENGINE=v3 acp`                       | same as `acp`                                     |

The assertions that follow cover the explicit `--agent-engine=v3` start for all
three inputs, its `--trust-tools` conflict, that an unselected
`acp --trust-tools` is not rejected at parse time, that
`--v3 acp --agent-engine=v2 --auth-method client` fails on `--auth-method`, not
on `--trust-tools`, and that the bare `--v3` launch with the grant reaches KAS.
Through the wrapper, every variant also starts KAS for an `acp-smoke` client.

## What is injected where

| Command                     | Flag                | Position    | Applies to                                                  |
| --------------------------- | ------------------- | ----------- | ----------------------------------------------------------- |
| `kiro-cli`                  | `--v3`              | **prepend** | every subcommand + bare                                     |
| `kiro-cli`                  | `--agent-engine=v3` | **append**  | `acp`, when the caller passed no `--agent-engine`           |
| `kiro-cli`, `kiro-cli-chat` | `--trust-tools=`    | **append**  | `chat` and the bare launch always; `acp` unless engine = v3 |

`kiro-cli-chat` is a temporary package alias for the same binary, kept for
consumers that still invoke it. It receives no `--v3`: an invocation through it
selects its engine itself.

The `acp` condition is resolved from **argv at runtime**, not from the Nix
config — see [the effective engine](#is-the-engine-v3-is-a-runtime-question).
The gate runs after the `--v3` prepend and the `acp` engine append, so both
injected selectors count.

Three different rules, for different reasons — do not "make them consistent":

- **`--v3` is global and wanted everywhere**, since it selects the engine for
  `chat` and the bare launch.
- **`--agent-engine=v3` is an `acp` option**, appended and only on `acp`,
  because `acp` does not read the global. It is skipped when the caller chose an
  engine.
- **`--trust-tools` belongs to the chat arguments**: `chat`, `acp` and the bare
  launch. Other subcommands reject it. It is appended and gated.

A prompt passed to a bare launch (`kiro-cli "explain this"`) gets **no**
`--trust-tools`. Its first positional cannot be told apart from an unknown
subcommand without a curated subcommand list that would drift with every
release, so the gate treats it as a subcommand and declines.
`kiro-cli chat "explain this"` carries the grant. `kiro-wrapper-argv` pins both
rows.

### Package-bound KAS and selected prompt patches

The native package's ordinary `makeWrapper` setup binds `KIRO_KAS_SERVER_PATH`
and `KIRO_KAS_NODE_PATH` for both `kiro-cli` and the `kiro-cli-chat` alias. KAS
comes from that CLI release's fetched input, never from the user's unpacked
cache. Fresh launches and launches with an older cache therefore use the same
selected store tree. Linux FHS and direct payloads share them.

Home Manager defaults `ai.kiro.cli.native.settings.app.disableAutoupdates` to
`true` in the global settings file it already owns when `cli.package` is
non-null. With `cli.package = null`, no updater default is added. Set it to
`false` to re-enable checks; the managed launcher also releases the package's
environment guard. An explicit `cli.environmentVariables.KIRO_NO_AUTO_UPDATE`
still wins. Devenv cannot write this global-only setting, so any update policy
there beyond the environment guard comes from the user's global settings.

Both package commands default `KIRO_NO_AUTO_UPDATE=1`. On devenv or with the
package alone, set it to `0`, `false`, `off`, `no` (case-insensitive), or empty
to re-enable checks. The guard unsets `KIRO_NO_AUTO_UPDATE` for those values and
sets it to `1` for anything else. Each command is a direct last hop to the
binary, so the guard runs once per launch. Any global
`app.disableAutoupdates = true` must also be released. This handles
presence-based consumers too. The binary's exact update-path semantics remain
unverified: isolated `--version` and unauthenticated probes reached only version
output or the authentication prompt. The stub-based
`kiro-autoupdate-wrapper-chain` check runs both commands' wrappers without
running Kiro.

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
time; `withRolloutFeatures`, `withFhsPayload` and `unwrapped` preserve that
selection. The factory uses the same selector on both backends. Every selected
exact source must occur once or the entire build fails before writing patched
output. Unselected prompt bytes remain unchanged. The independent CI drift check
requires both supported anchors in real vendor data on each platform even when a
consumer disables them.

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
initialization. `kiro-kas-dispatch` exercises the real `kiro-cli` and
`kiro-cli-chat` commands, CLI/ACP, fresh/stale homes, override precedence,
explicit V2 selection and a `trustedMcpTools` wrapper, plus raw argv
measurements on the stock binary. The FHS contract check separately inspects the
command paths inside the synthesized root; nested bubblewrap execution is not
portable inside a Nix build sandbox.

### `extraPackages` — a PATH prefix, not an FHS rebuild

`ai.kiro.cli.extraPackages` adds one more environment-only injection to both the
`kiro-cli` and `kiro-cli-chat` wrappers. Their store-backed `bin` directories
are prepended after ordinary and secret environment exports, so an explicit
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

The empty list is inert and produces no wrapper by itself. A non-empty list
creates the wrapper even when no env, argv, or secret injection is configured.
It does not alter argv, and `packages/kiro-cli/checks/kiro-wrapper-argv.nix`
runs both entry points to assert the prefix and inherited tail together.

On Linux this crosses the upstream FHS visibility boundary because `/nix` is
mounted and PATH is preserved; it does not merge packages into the synthesized
root. See [`fhs-sandbox.md`](fhs-sandbox.md) for why that distinction matters.

## LINUX PLACES THE TRUST WRAPPER INSIDE THE FHS PAYLOAD

> **Linux gained an FHS layer on post-split nixpkgs.** Since f13ff45a, the
> public package wraps `kiro-cli-unwrapped` in `buildFHSEnv`. nixpkgs 9ddfd8a
> later consolidated the original three per-command environments into one shared
> environment: `$out/bin/*` are thin wrappers selecting a command,
> `$out/libexec/kiro-cli/kiro-cli-wrapper` enters bubblewrap, and `/init`
> delegates through a three-line dispatcher before the selected command runs in
> the FHS root. This repo supplies its own pinned payload to that expression;
> our wrapProgram shims live on `passthru.unwrapped`. Flags and environment pass
> through every layer, so the contract in this document holds. PATH is
> **preserved** inside, but `/etc/profile` prepends
> `/run/wrappers/bin:/usr/bin:/usr/sbin`, so the root's own `/usr/bin` commands
> win over same-named entries later on PATH. See
> [`fhs-sandbox.md`](fhs-sandbox.md) for the bind rule, shadowed set, and loader
> trap. Darwin is unaffected — upstream returns the payload directly and builds
> no FHS layer. nixpkgs' FHS expression still lists `kiro-cli-term`, which 3.0.0
> no longer ships, so that one command wrapper fails with "command not found".

When `trustedMcpTools` is configured, the factory re-composes upstream's FHS
expression around a trust-wrapped payload, so the root's `/usr/bin/kiro-cli` and
`/usr/bin/kiro-cli-chat` carry the grant. In a Linux profile with
`trustedMcpTools` and `v3`:

```
kiro-cli acp
  -> outer wrapper     prepends --v3, appends --agent-engine=v3
  -> command wrapper   selects kiro-cli on the shared FHS launcher
  -> FHS /init         prepends the synthesized command directories
  -> dispatcher        execs the selected command
  -> /usr/bin/kiro-cli payload trust wrapper: sees v3, withholds on acp
  -> kiro-cli binary
```

The inner trust wrapper is built without a v3 setting of its own; it reads the
outer wrapper's `--v3` and `--agent-engine=v3` in argv, so injected and explicit
selectors behave the same. `kiro-wrapper-argv` drives this composition with a
stub FHS package (no bubblewrap) and `kiro-fhs-contract` pins the real launcher,
init, dispatcher and root commands. Home Manager's declarative permissions
translation remains an independent v3 path.

All other configuration remains outside the FHS package. Static and secret
environment exports, `extraPackages`, and `--v3` are inherited across bubblewrap
and keep their established ordering.

On Darwin the outer `kiro-cli` wrapper carries `--trust-tools` itself. Before
3.0.0 the Darwin launcher resolved a separate chat binary by app-bundle
discovery and skipped this repo's chat wrapper, so `--trust-tools` never reached
a `kiro-cli` launch there; it now does.

`ai.kiro.cli.useFhsSandbox = false` skips this package-composition layer
entirely and applies the ordinary wrappers to `passthru.unwrapped`. That is an
explicit compatibility tradeoff, not the default; see
[`fhs-sandbox.md`](fhs-sandbox.md) for the extracted-`bun` risk. Module
assertions inspect the rollout-resolved package and reject a custom FHS package
that advertises an unwrapped payload but cannot recompose it.

**Upstream's reason is NOT that v3 replaced the flag.** Under v3, `chat` still
honours it. `--trust-tools` is a **client-side** knob: kiro's own TUI
(`~/.local/share/kiro-cli/tui.js`) re-emits it onto the downstream ACP argv only
for the v2 child (`kiro-cli acp --agent-engine=v2 ...`). It never reaches the
KAS argv: KAS reads tool policy only from `permissions.yaml`, so under v3
`mkPermissionRules` is the trust delivery that works.

Do not over-read that. The TUI's auto-answer — selecting `allow_always` on an
`approval_request`, with an explicit branch for the v3 (`kas`) engine — is real
but is gated on **`--trust-all-tools`**, a different flag: `trustTools` occurs
exactly ONCE in `tui.js`, in the flag-spec table, and is never written to the
store or read by the approval handler. The auto-answer reads
`trustAllToolsConfirmed`.

On the `acp` arm kiro-cli **is** the agent and the external ACP client owns that
answer, so there is nothing agent-side for the flag to bind to — `acp-server.js`
contains no `trustedTools`/`trustAllTools` at all. The guard is deliberate, not
an unfinished port: the message is a hand-rolled literal in
`crates/chat-cli/src/cli/mod.rs` carrying its own flag list.

Little is lost for a **declarative** grant, with one caveat that matters by
backend. `trustedMcpTools` is also translated into `settings/permissions.yaml`
(`mkPermissionRules`), and the v3 agent does read that: `acp-server.js` declares
`POLICY_FILENAMES = ["permissions.yaml", "permissions.json"]` and layers
built-in → admin → `~/.kiro/settings/` → `~/.kiro/workspace-roots/<hash>/`,
compiling rules to Cedar. What the CLI flag cannot participate in is the
interactive half — under v3 an `ask` rule is resolved with the client over ACP
(`session/request_permission`).

**That recovery is home-manager-only.** `mkPermissionRules` has no devenv
equivalent, so on the devenv backend a withheld `--trust-tools` is not recovered
declaratively — the grant is simply absent for that session.

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

The rollout manifest is embedded in the chat binary and its names and vendor
state are extracted into the aggregate facts under
`packages/kiro-cli/extracted/`. `ai.kiro.cli.features.<name>.enable` exposes
those names; restricted entries are enabled by a length-preserving patch through
`passthru.withRolloutFeatures`, and entries already available to every user
preserve the stock package. Patch feasibility comes from
`rolloutPatchability.<name>.patchable`, measured with the patcher’s shared entry
matcher. Enabling an unpatchable feature fails at evaluation and names the
extracted flag when a patch is needed. These patches require `cli.v3 = true`
because the feature surfaces use the `kas` engine.

Workflows are GA since 2.26.0 and need no binary patch. `cli.workflows.enable`
still requires v3 and the global `chat.enableWorkflows` setting; Home Manager
implies it and devenv warns when it is absent. `codeToSpec`,
`backgroundExecution`, `kvim` and `sandbox` are friendly switches over
restricted rollout names, with client-setting and launch prerequisites described
in [`workflow-gating.md`](workflow-gating.md). Raw feature switches change
availability only. Typed `cli.native.settings.chat.keybindings` declarations
follow the extracted registry; background execution can be rebound with
`moveToBackground` in the global settings.

### "Is the engine v3" is a RUNTIME question

A caller's `--agent-engine` overrides `--v3`, so an eval-time `hasV3` gets it
wrong in both directions, and both were measured on 2.x:

```console
$ kiro-cli --v3 acp --agent-engine=v2 --trust-tools=x     # runs — v2, so trust is valid
$ kiro-cli      acp --agent-engine=v3 --trust-tools=x     # CONFLICT — v3, even with v3 off in Nix
```

Gating on `hasV3` alone would silently drop trust in the first case and break
the command in the second. So the gate resolves the engine from argv before any
`--`: the last `--agent-engine` value (either spelling) if present; otherwise v3
if an exact `--v3` token is present, whether the `kiro-cli` wrapper injected it
or the caller typed it; otherwise a sentinel. It withholds only when that
resolves to `v3`.

The fallback is deliberately a sentinel, not the binary's default and not what
this Nix config bakes in. The configured `--v3` only exists in argv when the
`kiro-cli` wrapper put it there, so reading argv is exact. On 2.x a bare `--tui`
measured the chat binary's default as `v1`, not the `v2` this fragment once
claimed; a sentinel cannot go stale when upstream moves the default again.

3.0.0 has a client-dependent default for an `acp` with no selector (see
[above](#acp-takes-its-engine-from-acp-not-from---v3)). `kiro-kas-dispatch`
asserts that an unselected `acp --trust-tools` is not rejected at parse time;
the gate keeps the grant there, so with v3 not configured it is the appended
`--trust-tools` that makes such an `acp` default to v2. `acp.agentEngine` also
selects the `acp` engine, and `chat.agentEngine` the chat one. The gate reads
neither setting, so `ai.kiro.cli.v3` delivers v3 as argv only: `--v3`, plus
`--agent-engine=v3` on `acp`.

## The v3 + `acp` conflict

`--agent-engine=v3` on `acp` is declared mutually exclusive with **every option
`acp` had on 2.15.2** — `--agent`, `--model`, `--effort`, `--trust-tools`,
`-a/--trust-all-tools`. On 2.15.2 only `-v` survived. 2.24.1 adds the inverse
case: `acp --auth-method <METHOD>` is accepted ONLY under v3, and under `v2` it
fails with "--auth-method is only supported with --agent-engine=v3" (measured on
2.24.1).

The conflict is value-specific — `=v1`/`=v2` accept all five (measured on
2.15.2) — and, on 2.24.1, `acp`-specific. Both columns were measured on 2.24.1
against the unwrapped chat binary, with `chat` given input under each of `--v3`,
`--agent-engine v3` and `--agent-engine=v3`:

| Option under v3                  | on `acp` | on `chat` |
| -------------------------------- | -------- | --------- |
| `--agent`, `--model`, `--effort` | conflict | accepted  |
| `--trust-tools`                  | conflict | accepted  |
| `-a` / `--trust-all-tools`       | conflict | accepted  |

The `-a` row on `chat` was a conflict on 2.15.2, so the set has moved between
releases: re-measure it on a bump (step 4 of the recipe below) rather than carry
this table forward. This wrapper is unaffected either way — it injects
`--trust-tools`, never `--trust-all-tools`.

A `chat` probe needs input supplied. Without it, `--no-interactive` reports
"Input must be supplied when running in non-interactive mode" before any
engine-conflict check, so it cannot tell an accepted flag from a rejected one.
On 2.x, `acp` rejected a conflicting option before it read any input; the 3.0.0
`acp` probes in `kiro-kas-dispatch` therefore send an ACP initialize.

**Consequence for a consumer:** with `ai.kiro.cli.v3 = true`, an invocation like
`kiro-cli acp --model auto` fails with upstream's conflict error, because the
wrapper appends `--agent-engine=v3`. That is deliberate. The alternative —
withholding the selector whenever a conflicting option appears — would silently
downgrade the engine the user asked for (upstream's own default does exactly
that on 3.0.0), and would require this repo to carry a hand-curated conflict
list that rots on every upstream release.

Nothing is made unreachable: the caller opts out per-invocation with
`--agent-engine=v2`, which the wrapper leaves alone and upstream honours:

```console
$ kiro-cli acp --agent-engine=v2 --model auto     # runs
```

Note the error names `--agent-engine=v3`, a flag the user never typed. That is
confusing on first contact and worth repeating in user-facing docs.

## How the scan decides (`lib/idempotentFlags.nix`)

`subcommandBlock` walks argv left to right and stops at the first token that is
neither an option nor an option's **value**:

- **Value-taking options must be listed.** `launchValueFlags` in
  `wrapPackage.nix` lists the 3.0.0 top-level ones (`--agent`, `--model`,
  `--agent-engine`, `--resume-id` and others), sourced from the binary's
  chat-argument strings and the TUI's launch-flag table. Without the skip,
  `kiro-cli --agent acp` reads as the `acp` subcommand and a bare launch
  silently loses the grant. An unlisted value flag fails safe: its value reads
  as a subcommand and the grant is withheld. The `--opt=value` form needs no
  entry: one token, handled by the `-*` arm.
- **`--` parks on a sentinel** no gate matches, so gated injection declines
  rather than guessing.

`idempotentFlagBlock` takes an explicit `position` with **no default** — picking
the wrong one is precisely the bug above. `--v3` aborts on repetition ("cannot
be used multiple times"), so it is injected only when absent as an **exact argv
token** — not a substring scan of `"$*"`, so `kiro-cli chat 'explain --v3'`
still gets the real flag.

`flagPresenceBlock` answers "is `--v3` present" with the same exact-token rule,
stopping at `--`.

`--trust-tools` is not idempotence-guarded: repeating it is _accepted_ by both
`chat` and `acp` (measured on 2.x), unlike the boolean flags.

## Re-measuring on a version bump

Run against the **unwrapped** binary out of `nix build` — a bare `PATH` lookup
finds the wrapper, which is the thing under test.

Since 3.0.0 there is one binary on both platforms and no `PATH` dispatch, so the
recipe is the same on darwin. Invoke `$K/bin/kiro-cli` from `passthru.unwrapped`
for raw parse results; the module's wrappers are the thing under test.

```bash
K=$(nix build --no-link --print-out-paths .#ciPackages.x86_64-linux.kiro-cli.unwrapped); KB="$K/bin/kiro-cli"

# 1. globals still parse BEFORE a subcommand, and still fail after it
"$KB" --tui --v3 whoami >/dev/null && echo "prepend ok"
"$KB" whoami --tui --v3 2>&1 | grep -q "unexpected argument" && echo "append still fails"

# 2. acp still ignores the global --v3: a trust flag does not conflict
"$KB" --v3 acp --trust-tools=x </dev/null 2>&1 | grep -q "agent-engine=v3" \
  && echo "CHANGED: --v3 reaches acp again, drop acpEngineBlock" || echo "acp still ignores --v3"

# 3. a caller's engine still wins over the injected --v3
"$KB" --v3 acp --agent-engine=v2 --model auto </dev/null 2>&1 | grep -q "not supported" \
  && echo "REGRESSION: escape hatch gone" || echo "escape hatch intact"

# 4. the v3 conflict table. Each line prints the exit status, then the
#    verdict. "not supported with --agent-engine=v3: <opt>" (exit 2) means
#    conflict. The empty first entry is the baseline: if it conflicts, the
#    engine or a fixed option is the cause, not the row. acp rejects a conflict
#    before it reads any input, so it needs none; a baseline that is accepted
#    starts the server and exits 0 when stdin closes:
for opt in "" "--auth-method cli" "--agent x" "--model auto" "--effort low" \
  "--trust-tools=x" "-a" "--trust-all-tools"; do
  out=$("$KB" acp --agent-engine v3 $opt </dev/null 2>&1)
  echo "[$opt] $? ${out%%$'\n'*}"
done
#    the inverse case: expect "--auth-method is only supported with
#    --agent-engine=v3" (exit 2)
"$KB" acp --agent-engine v2 --auth-method cli </dev/null 2>&1 | head -1
#    chat needs input, and an invalid model id, so the call parses but never
#    generates. Accepted means it reaches the server and reports the model as
#    "not available"; a conflict is the same "not supported with
#    --agent-engine=v3" text naming the option. Read any other error before
#    scoring it. `--agent x` names no existing agent: on 2.24.1 v3 does not
#    reject an unknown agent before the model call, so "not available" still
#    means accepted. Repeat under --v3 and --agent-engine=v3.
for opt in "" "--agent x" "--effort low" "--trust-tools=x" "-a" \
  "--trust-all-tools"; do
  out=$("$KB" chat --agent-engine v3 --no-interactive $opt \
    --model zz-not-a-model 'Reply OK' </dev/null 2>&1)
  echo "[$opt] $? $(grep -m1 -oE 'is not available|not supported with --agent-engine=v3.*' <<<"$out")"
done
```

Read `--help-all` for the launcher's own options (that Options block is what
"global" means here) and each subcommand's `--help` for its own. Confirm with a
parse probe rather than trusting help text — use an argument that fails
validation LATE, so "unexpected argument" versus "invalid value" distinguishes a
parse rejection from an accepted flag.

## Tests

- `packages/kiro-cli/checks/kiro-fhs-contract.nix` — structurally inspects the
  realized upstream Linux command wrappers, shared launcher, init, dispatcher,
  and profile. It pins the `/nix` bind and inherited PATH bridge that
  `extraPackages` depends on, then realizes a configured FHS payload and proves
  the rootfs `kiro-cli` and `kiro-cli-chat` commands carry `trustedMcpTools`,
  without claiming to execute bubblewrap inside the Nix build sandbox.
- `packages/kiro-cli/checks/kiro-wrapper-argv.nix` — the real wrapper against a
  stub package that prints its argv, on both platforms. Covers which SIDE of the
  subcommand each flag lands on, the absence of `--tui`, the value-flag skip,
  `--`, idempotence, the trust gate under injected and explicit `--v3` and
  `--agent-engine`, the Linux FHS composition through a stub FHS package, and
  the env/PATH export paths. String-matching the generated bash cannot catch a
  flag emitted on the wrong side; running it can.
- `packages/kiro-cli/checks/module-eval.nix` (`module-kiro-wrapper-*`) — pins
  the SHAPE of the generated bash and the wrapper trigger conditions.

## Do not break the exec line

The wrapper ends with `exec -a "$0" <realBin> "$@"`. Keep that shape: recovering
the real binary by reading the line back out of the generated wrapper is how you
probe the unwrapped CLI at all (see the re-measure recipe above), and
`packages/kiro-cli/checks/kiro-wrapper-argv.nix` asserts on it.

This governs THIS module's wrappers only. The package's own `kiro-cli-chat`
alias ends in `exec -a kiro-cli`, so the binary sees a `kiro-cli` launch; the
check never reads that wrapper.

An earlier revision credited "probe scripts under `docs/plans/`" with depending
on this. Nothing there does — `grep -rl 'exec -a' docs/plans` is empty — so the
check is the only thing pinning it.

## Optional usage capture

`cli.usageTracking.enable` is another managed-wrapper reason on both backends.
Before either public Kiro launcher executes its real binary, it rejects a non-v3
`--agent-engine` override and requires the private usage service's CA and
loopback listener, rejects inherited proxy conflicts, and exports the local
HTTP(S) proxy and Node extra CA only for Kiro's process tree. A `kiro-cli-chat`
call must select v3 with `--agent-engine v3` or `--v3`; the configured `cli.v3`
injection belongs only to `kiro-cli`. These exports remain outside the FHS
package and are inherited across it, like the existing static environment. The
disabled path keeps the existing wrapper behavior. The same wrapper package
installs `kiro-usage` for explicit indexing, session queries, and unpacking. Its
`exec` command reuses the same readiness and environment preparation for a
PATH-selected command, explicitly replaces inherited conflicts, and composes
with the managed wrapper. Named `kiro-cli` commands receive an idempotent
`--v3`; generic commands keep their arguments. See
[usage-tracking.md](usage-tracking.md) for options, service lifecycle, scope,
and limitations.
