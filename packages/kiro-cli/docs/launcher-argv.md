# kiro-cli wrapper: the argv contract

<!-- cspell:ignore avante codecompanion cutover vwalways walways wnever -->

> **Last verified:** 2026-11-06 — Kiro CLI 3.0.0 ships one `kiro-cli` binary.
> The wrapper always prepends `--v3` and adds `--agent-engine=v3` to `acp`
> (before an end-of-options `--`, else last) unless the caller passed an
> `--agent-engine`; it injects no trust flag. Its subcommand scan skips the
> values of the top-level options the binary's `--help` lists as taking one.
> Four consumer options (`ai.kiro.cli.chat.{mode,wrap,requireMcpStartup}` and
> `ai.kiro.cli.acp.authMethod`) add their flag the same way, and a bare launch
> is rewritten to `chat` when a chat option is set. The 3.0.0 facts below are
> read from the binary and asserted by `kiro-kas-dispatch`; 2.x measurements are
> labelled as such. Engine-start probes need the fixture key (`probing.md`).
>
> **Settled — do not relitigate.** Full lineage:
> `git show 0057d8ed:packages/kiro-cli/docs/launcher-argv.md`.
>
> - A blanket "every claim below is a MEASURED parse result" framing once
>   shipped four wrong claims unqualified. Source each claim individually —
>   measured vs. sourced-to-file — and re-measure rather than reason.
> - The module runs only the v3 engine. There is no engine option and no v2
>   path; a caller who types `--agent-engine=v2` reaches upstream unmodified,
>   which this repo does not test. When the binary ships several agent engines,
>   the wrapper pins the newest one it ships, and when an upstream release drops
>   the selector, the wrapper drops the flag; both are measured from that
>   release's `--help` at bump time, never assumed.

## What is injected where

| Flag                                                | Position                      | Applies to                                                                                      |
| --------------------------------------------------- | ----------------------------- | ----------------------------------------------------------------------------------------------- |
| `--v3`                                              | **prepend**                   | every subcommand + bare, unless already present                                                 |
| `--agent-engine=v3`                                 | **after `acp`**, before `--`  | `acp`, when the caller passed no `--agent-engine`                                               |
| `--mode=<v>`, `--wrap=<v>`, `--require-mcp-startup` | **after `chat`**, before `--` | `chat`, and a bare launch rewritten to it; only for a configured option the caller did not pass |
| `--auth-method=<v>`                                 | **after `acp`**, before `--`  | `acp`, when configured and the caller passed no `--auth-method` or alias                        |

All live in `lib/wrapPackage.nix`. Do not "make them consistent": `--v3` is a
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
for all three. That start needs the CI harness
(`packages/kiro-cli/checks/kas-dispatch.py`), which supplies the `KIRO_API_KEY`
fixture, the package bin on `PATH` and its own node through
`KIRO_KAS_NODE_PATH`; without credentials the 3.0.0 binary stops first at the
login gate (`probing.md`). So the wrapper adds `--agent-engine=v3` to `acp`
unless an `--agent-engine` token, in either spelling, is already before `--`.
The scan reads presence only; a caller's own selector, whatever its value, is
left to upstream. The selector goes in front of an end-of-options `--` (a token
past it is a positional) and last when argv has no `--`: `acp --` becomes
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

The wrapper injects no `--trust-tools`, `--trust-all-tools` or
`--trust-workspace`. Under v3 no process hands the list to KAS:

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

## Consumer options for `chat` and `acp`

`lib/cliOptions.nix` classifies every option of the three `--help` tables in
`cli.options` (`top`, `chat`, `acp`): a setting, or an exclusion with a reason
(`one-off`, `mode`, `wrapper-owned`, `rejected-on-v3`, `trust-settled`,
`duplicates-a-workspace-setting`, `no-v3-effect`). `report` diffs the table
against the committed extraction, and `module-kiro-launch-option-classification`
fails on an option with no row or a row whose option is gone. Four options are
settings, each `nullOr` with default `null` and typed from the extracted record
(an enum from its possible values, a bool for a flag with none):

| Option                               | Flag                    | Type                       |
| ------------------------------------ | ----------------------- | -------------------------- |
| `ai.kiro.cli.chat.mode`              | `--mode`                | `default`, `spec`          |
| `ai.kiro.cli.chat.requireMcpStartup` | `--require-mcp-startup` | bool; false passes nothing |
| `ai.kiro.cli.chat.wrap`              | `--wrap`                | `always`, `never`, `auto`  |
| `ai.kiro.cli.acp.authMethod`         | `--auth-method`         | `cli`, `client`            |

3.0.0's parser rejects a value outside the declared set
(`--v3 chat --wrap=foo --help` and `--v3 chat --mode=foo --help` exit 2 with
`invalid value 'foo'`), and the option enums take the same values, so a wrong
value fails at evaluation instead of at launch. `--agent`, `--model` and
`--effort` are not settings here: a workspace setting (`chat.defaultAgent`,
`chat.defaultModel`, `chat.modelDefaults`) already sets each, and `acp` rejects
all three under `--agent-engine=v3`. The trust flags stay out (see above), as do
the modes (`--sessions`, `--no-interactive`, `--output-format`, `--cloud`,
`--repo`) and `--tui`/`--legacy-ui`, which the pinned v3 launch supersedes. The
same four options exist on Home Manager and devenv, and `package = null` warns
when one is set, because they need the managed wrapper.

Two rules sit on the classification. An environment variable joins it only once
it has been measured (`probing.md`), because `lib/cliOptions.nix` reads the
`--help` tables only and exposes nothing for a variable. In
`packages/kiro-cli/checks/kiro-cli-extracted.nix` a check holds an exact
expectation only where this package's code consumes the value; every other row
is a membership expectation, so an upstream addition is drift that regeneration
clears instead of a red check.

A configured option becomes one `--name=value` word, added only when the caller
passed none of its spellings before `--`: the long name and aliases as `--x v`
or `--x=v`, the short name as `-w v` or `-wv`, and the short name inside a
cluster of short options (`-vw always`, `-vwalways`), read the way the parser
reads it (see the scan below). The word goes after the subcommand and any INPUT,
in front of an end-of-options `--`, the same placement as `acp`'s engine
selector.

**A bare launch becomes `chat`** when argv before `--` has no subcommand or
other positional token (an empty argument or a lone `-` counts as one), none of
the once-per-invocation top-level options (`--help`, `--version`, `--resume`,
`--resume-id`, `--resume-picker` and its `--list` alias, `--verbose`, all
classified `one-off`, plus the hidden `--help-all`), whether spelled long, short
or inside a cluster (`-rv` is `-r` and `-v`, both one-off), no value option
still waiting for its value, and at least one chat option adds a word. `chat` is
appended after the top-level options, so `kiro-cli --agent a` becomes
`--v3 --agent a chat ...`. Rejected by the rewrite: `chat` has no
`-V`/`--version`, no `--list` alias and no `--help-all`, so rewriting those
would swap a result for an error; and `kiro-cli --agent` would read the appended
`chat` as the agent's name. `settings`, `login`, `acp`, `mcp` and every other
subcommand are untouched, as is a bare launch with an INPUT, `--`, or no chat
option set.

Measured on the stock 3.0.0 binary (empty `HOME`, `KIRO_NO_AUTO_UPDATE=1`, stdin
from `/dev/null`), with `--help` last so a parse failure in any earlier token
shows first:

| argv the wrapper produces                                                   | exit | first line                                                              |
| --------------------------------------------------------------------------- | ---- | ----------------------------------------------------------------------- |
| `--v3 chat --mode=spec --require-mcp-startup --wrap=never --help`           | 0    | `AI assistant in your terminal`                                         |
| `--v3 --agent a chat --mode=spec --require-mcp-startup --wrap=never --help` | 0    | `AI assistant in your terminal`                                         |
| `--v3 chat hello --mode=spec --require-mcp-startup --wrap=never --help`     | 0    | `AI assistant in your terminal`                                         |
| `--v3 chat -wnever --mode=spec --require-mcp-startup --help`                | 0    | `AI assistant in your terminal`                                         |
| `--v3 acp --agent-engine=v3 --auth-method=client --help`                    | 0    | `Start Agent Client Protocol (ACP) agent`                               |
| `--v3 acp --agent-engine=v3 --auth-method=cli --help`                       | 0    | `Start Agent Client Protocol (ACP) agent`                               |
| `--v3 chat --mode=spec --require-mcp-startup --wrap=never -- hello --help`  | 2    | `error: unrecognized subcommand '--help'` (same as without the options) |
| `--v3 --version`, `--v3 -V`, `--v3 --help-all`, `--v3 --resume-id x --help` | 0    | version or `The Kiro CLI` help, argv not rewritten                      |
| `--v3 chat --wrap never --wrap=always --help`                               | 2    | `the argument '--wrap <WRAP>' cannot be used multiple times`            |

Short options in a cluster, same conditions. The `-w` rows show the parser
reading `-vw always` and `-vwalways` as `-v -w always` (a repeat is refused),
and `-wv` and `-dw` as a value-taking short that takes the rest of the token;
the `-r` rows show `-rv` and `-vr` as `-r` plus `-v` (a second `--resume` is
refused):

| argv                                       | exit | first line                                                       |
| ------------------------------------------ | ---- | ---------------------------------------------------------------- |
| `--v3 chat -vw always --help`              | 0    | `AI assistant in your terminal`                                  |
| `--v3 chat -vw always --wrap=never --help` | 2    | `the argument '--wrap <WRAP>' cannot be used multiple times`     |
| `--v3 chat -vwalways --help`               | 0    | `AI assistant in your terminal`                                  |
| `--v3 chat -vwalways --wrap=never --help`  | 2    | `the argument '--wrap <WRAP>' cannot be used multiple times`     |
| `--v3 chat -wv --wrap=never --help`        | 2    | `invalid value 'v' for '--wrap <WRAP>'` (`-w` took `v` as value) |
| `--v3 chat -dw --wrap=never --help`        | 0    | `AI assistant in your terminal` (`-d` took `w`; `--wrap` is new) |
| `--v3 chat -v --wrap=never --help`         | 0    | `AI assistant in your terminal`                                  |
| `--v3 -rv --help`                          | 0    | `The Kiro CLI`                                                   |
| `--v3 -rv --resume --help`                 | 2    | `the argument '--resume' cannot be used multiple times`          |
| `--v3 -vr --resume --help`                 | 2    | `the argument '--resume' cannot be used multiple times`          |

`kiro-cli chat --help-all` is rejected (exit 2), which is why the rewrite spares
`--help-all`.

`kiro-usage exec kiro-cli ...` runs the PATH-selected `kiro-cli`, the managed
wrapper, and its own argv logic does insert two words before it: `--v3` unless a
token before `--` is one (`usage/runtime.py:278`) and, for `acp`,
`--agent-engine=v3` before `--` unless an `--agent-engine` is there
(`usage/runtime.py:284`), and the result is what it executes (`os.execvpe` at
`:292`, `wait_command` at `:295`). That is idempotent with the launcher: the
launcher's scans find both selectors already present and add nothing, so each
appears once. The four options of this section are injected only by the
launcher; `exec` never adds one, and a bare launch is captured the same whether
or not the launcher then makes it `chat`.

## How the scan decides (`lib/idempotentFlags.nix`)

`gateOnSubcommand` runs `subcommandBlock`, which walks argv left to right and
stops at the first token that is neither an option nor an option's **value**:

- **Value-taking options must be listed, and the list is measured.** The scan
  skips the next token after each top-level option that takes a value, spelled
  by long name, short name and alias. 3.0.0's top level has three: `--agent`,
  `--resume-id` and `--repo`. The list comes from the `top` table of
  `cli.options` in `extracted/`, which `extract/cli-help.py` reads from the
  payload's `kiro-cli --help` (`lib/launchValueOptions.nix` derives the names).
  The same names reach `kiro-usage exec` as `--launch-value-options`, so the
  launcher and the usage tool cannot disagree. Without the skip,
  `kiro-cli --agent acp` reads as the `acp` subcommand and a bare launch gets
  `--agent-engine=v3`, which its parser rejects. An option the top level does
  not parse, such as `--model` (a `chat` and `acp` option), is not skipped:
  upstream rejects `kiro-cli --model acp` at the top level, so nothing launches
  and the scan reads `acp` as the subcommand. The `--opt=value` form needs no
  entry: one token, handled by the `-*` arm.
- **Short options are read as clusters, from the same table.** The scan that
  looks for a configured option (or a top-level one-off) is given the short
  options of the subcommand's `--help` table (`shortOptions` in
  `lib/cliOptions.nix`: `chat` has `-a -d -f -h -l -r -v -w`, of which `-d`,
  `-f` and `-w` take a value; the top level has `-h -r -v -V`, none taking one).
  A token `-abc` (one dash, not `--`, not `-` alone) is read left to right, as
  the parser does: a short that takes a value ends the token, the rest of it
  being the value or, when nothing follows, the next token; a character not in
  the table ends the token without a guess. So `chat -vw always` and
  `chat -vwalways` have `--wrap`, `chat -wv` has `-w` with the value `v`,
  `chat -dw` has `-d` with the value `w` and no `--wrap`, and a bare `-rv` or
  `-vr` has once-per-invocation options. Only callers that pass `shorts` read
  clusters; the `acp` scan, which has no setting with a short name, and every
  other caller keep whole-token matching.
- **Shared helper changes are opt-in.** A change to `lib/idempotentFlags.nix`
  keeps every other caller's generated text byte-identical: new behavior (such
  as `shorts`) is selected per caller, never by changing a default.
- **`--` parks on a sentinel** no gate matches, so gated injection declines
  rather than guessing.
- **A dangling value option is visible.** `nat_skip` is 1 when the scan ends
  right after a value option, which is how the bare-launch rewrite avoids
  appending `chat` as that option's value.

`idempotentFlagBlock` takes an explicit `position` with **no default** — picking
the wrong one is precisely the bug above. `optionPresenceBlock` reports whether
an option occurs before `--` as `--flag` or `--flag=value` (also an alias, the
short name and its attached form), and never reads the value;
`injectOptionsBlock` adds the words of the options that do not, before `--`.

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

That is not final override precedence on Linux. This package's FHS `/init` then
sources `/etc/profile`, which puts `/run/wrappers/bin:/usr/bin:/usr/sbin` ahead
of the inherited entries. The requested package remains visible, but a
same-named command already in the synthesized root wins. This option is for
supplying missing tools; Darwin has no later FHS reordering.

The empty list is inert. A non-empty list does not alter argv, and
`packages/kiro-cli/checks/kiro-wrapper-argv.nix` runs the launcher to assert the
prefix and inherited tail together.

On Linux this crosses the FHS visibility boundary because `/nix` is mounted and
PATH is preserved; it does not merge packages into the synthesized root. See
[`fhs-sandbox.md`](fhs-sandbox.md) for why that distinction matters.

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

Workflows have no rollout entry since 3.1.0 and need no binary patch.
`cli.workflows.enable` still requires the global `chat.enableWorkflows` setting;
Home Manager implies it and devenv warns when it is absent. `codeToSpec`,
`backgroundExecution` and `kvim` are friendly switches over restricted rollout
names, with client-setting and launch prerequisites described in
[`workflow-gating.md`](workflow-gating.md). Raw feature switches change
availability only. Typed `cli.native.settings.chat.keybindings` declarations
follow the extracted registry, which includes `quit` on 3.2.1. For example,
`cli.native.settings.chat.keybindings.quit = "ctrl+x"` overrides that binding.

## Re-measuring on a version bump

Run against the **unwrapped** binary — a bare `PATH` lookup finds the wrapper,
which is the thing under test. One binary serves both platforms. Every command
goes through `probe`, the scrubbed-environment launcher in
[`probing.md`](probing.md), never with only a scratch `HOME`. Step 1 is a flag
probe and steps 2 and 3 are dispatch probes there, so none starts the agent
server.

```bash
K=$(nix build --no-link --print-out-paths .#ciPackages.x86_64-linux.kiro-cli.unwrapped); KB="$K/bin/kiro-cli"

# 1. globals still parse BEFORE a subcommand, and still fail after it
probe "$KB" --v3 whoami --help >/dev/null && echo "prepend ok"
probe "$KB" whoami --v3 --help 2>&1 | grep -q "unexpected argument" && echo "append still fails"

# 2. the acp engine resolution, as dispatch probes: plain `acp` shows
#    upstream's default, `acp --agent-engine v3` must print "KAS spawned:".
#    The kiro-kas-dispatch check's MEASURE rows in CI cover the raw
#    `acp --agent-engine=v3` for EOF, nix-check and acp-smoke; each must show
#    "started": true.
PROBE_CLASS=dispatch probe "$KB" acp
PROBE_CLASS=dispatch probe "$KB" acp --agent-engine v3

# 3. the v3 conflict set on acp: a conflict exits 2 with "not supported with
#    --agent-engine=v3: <opt>" and spawns no KAS; the empty baseline exits 0
#    and prints "KAS spawned:".
for opt in "" "--agent x" "--model auto" "--effort low" "--trust-tools=x" "-a"; do
  out=$(PROBE_CLASS=dispatch probe "$KB" acp --agent-engine v3 $opt 2>&1)
  echo "[$opt] $? ${out%%$'\n'*}"
done
```

Read `--help-all` for the launcher's own options (that Options block is what
"global" means here) and each subcommand's `--help` for its own. Confirm with a
parse probe rather than trusting help text — use an argument that fails
validation LATE, so "unexpected argument" versus "invalid value" distinguishes a
parse rejection from an accepted flag.

The option tables of `kiro-cli`, `chat` and `acp` need no hand re-measure: the
`kiro-cli-extracted` check runs `extract/cli-help.py` against the Linux payload,
prints the whole table in its build log and fails when it differs from the
committed `cli.options` facts. Regenerate with
`nix run .#checks.x86_64-linux.kiro-cli-extracted.passthru.regenerate`. The
tables are measured on x86_64-linux only: clap compiles each platform's tables
from one source, so Darwin has no host-run job for them.

## Tests

- `packages/kiro-cli/checks/kiro-wrapper-argv.nix` — the real wrapper against a
  stub package that prints its argv. Covers which SIDE of the subcommand each
  flag lands on, the value-flag skip (`--agent`, `--resume-id`, `--repo`, and
  `--model` not skipped), `--`, idempotence of `--v3`, the presence-only `acp`
  selector, the absence of `--trust-tools`, and the env/PATH export paths.
- `packages/kiro-cli/checks/kiro-wrapper-argv.nix` also covers the configured
  options: placement after `chat` and `acp`, the caller's `--wrap=never`,
  `--wrap never`, `-w`, `-walways`, the clusters `-vw always`, `-vwalways`,
  `-wv` and `-dw`, `--authMethod`, `--` with options after it, the bare-launch
  rewrite and each argv it must leave alone (`--version`, `-V`, `--help`, `-h`,
  `--help-all`, `-v`, `-rv`, `-vr`, `--resume-id x`, `settings`, `login`, a
  prompt, a dangling `--agent`), and that no trust flag or Kiro home appears.
- `packages/kiro-cli/checks/module-eval.nix` (`module-kiro-launch-option-*`,
  `module-kiro-{hm,devenv}-launch-options*`,
  `module-kiro-package-null-explicit-launch-options-warn`) — the classification
  against the extraction and the exact four settings, enum refusal at
  evaluation, the same launcher content on both backends, null and false
  injecting nothing, and the `package = null` warning.
- `packages/kiro-cli/checks/kiro-cli-extracted.nix` — the drift check for
  `cli.options` (exact rows for the top-level value options this change reads;
  membership rows for `v3` in `acp --agent-engine`, `cli` in `acp --auth-method`
  and `json` in `chat --format`) and `kiro-cli-help-fixtures`, which runs the
  parser on the real 3.0.0 help output under `checks/fixtures/help/` and on
  three inputs it must refuse.
- `packages/kiro-cli/checks/module-eval.nix`
  (`module-kiro-launch-value-options`) — the measured value-option list, and
  that a short name and an alias of a value option are skipped too.
- `packages/kiro-cli/checks/kas-dispatch.py` (`kiro-kas-dispatch`) — the real
  3.0.0 binary through the wrapper, and the raw `acp --agent-engine=v3`
  measurement.
- `packages/kiro-cli/checks/kiro-fhs-contract.nix` — structurally inspects the
  realized Linux launcher, init and profile of the package's own FHS env, for
  the default and a selected variant, without executing bubblewrap inside the
  Nix build sandbox.
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
