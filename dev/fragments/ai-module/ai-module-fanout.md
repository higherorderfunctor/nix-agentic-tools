## ai Module Fanout Semantics

> **Last verified:** 2026-10-30 — non-`each` gaps inspect runtime pool, root and
> normalized inputs in order and warn once for the first input holding the
> requested field. Root copy-down names the runtime pool; keyed-entry gaps
> retain their existing selection. Network `ai.proxy` copies fields down at
> default priority with explicit null opt-outs; Claude's managed launcher also
> delivers selected intercepting proxy CA trust before startup.
>
> **Settled — do not relitigate.** Each of these records an approach that was
> TRIED and rejected, or a measurement that would otherwise be re-derived
> wrongly. Full lineage:
> `git show d1c28a21:dev/fragments/ai-module/ai-module-fanout.md`.
>
> - **There is no shared `ai.lspServers` pool — don't restore it.** It fanned
>   one typed record out to Claude, Copilot and Kiro until the operator removed
>   it on 2026-10-14 (#2526) because nobody set it; a normalized surface returns
>   only when two harnesses share a lossless shape. Native settings options stay
>   and no new native LSP option replaces it. Two measurements that would
>   otherwise be re-derived: under Home Manager, Copilot's LSP toggle renames a
>   temporary over `lsp-config.json`, so a symlinked file there is replaced and
>   a consumer must deliver a real copy; Kiro reads `settings/lsp.json` relative
>   to the workspace, so a copy under `$HOME/.kiro` is live only when the
>   workspace is `$HOME`. Last version:
>   `git show 0964eec2:lib/ai/sharedOptions.nix`.
> - **Root silence for unsupported runtimes is rejected.** It was the design,
>   rejected by the operator on 2026-10-13; repeated activation warnings,
>   including Copilot's, are accepted. Prior design:
>   `git show 17060194:dev/fragments/ai-module/ai-module-fanout.md`.
> - **No per-backend delivery callback on the runtime record.** A backend spec's
>   own `config` let a runtime lower each backend separately, and the untyped
>   callbacks grew into near-duplicate per-backend delivery bodies that the
>   delivery layer now replaces. One record-level `config` receives `backend`
>   for a real scope difference; the record-level `transformers` and
>   `defaults.outputPath` fields, which nothing read, are gone with it.
> - **Codex's beta permission model doesn't merge with legacy sandbox settings —
>   it overrides them, silently.** A layer carrying the beta model replaces the
>   legacy `sandbox_workspace_write` roots beneath it, and Nix evaluation can't
>   see across config layers to catch that. Measured with `codex sandbox`
>   0.146.1, where this repo's own former profile silently dropped the
>   module-contributed `~/.cache/nix` root — hence the hard assert rejecting the
>   combination rather than trying to reconcile it.
> - **`ai.kiro.native.agents.<name>` defaults `name` from the attribute key —
>   don't remove it as redundant.** Kiro ships two agent-schema parsers with
>   different requirements: the Rust CLI requires `name`, the Node/ACP parser
>   treats it as optional. The default satisfies both.
> - **`ai.codex.profiles` cannot deliver "this agent sees only X" — dropped
>   2026-09-19, not merely re-locked.** The whole-file `codex --profile <name>`
>   layer was locked out by assertion from the day it landed (a profile layer
>   silently overrides legacy sandbox settings in the user config beneath it),
>   which left the option and its HM/devenv materializer unreachable dead code.
>   It would not have delivered the per-agent skill/context visibility it was
>   kept around for even if unlocked: a Codex profile is a User-layer config
>   file (precedence 21) that cannot restrict which skills or AGENTS.md files
>   Codex discovers. Revisit alongside the sandbox-stack work, which builds the
>   actual mechanism (a distinct `CODEX_HOME` or a restricted filesystem view).
> - **Codex's hand-classified command and flag ledger is retired — don't bring
>   it back.** It required a person to classify every new upstream name, and its
>   field ledgers pinned our own extractor's output. By operator decision
>   (2026-10), extracted names need no acceptance rows; launcher flags stay
>   guarded as `uses`. The ledger and its `--worktree` and `exec-server forward`
>   reclassification notes:
>   `git show 60bfb552:packages/chatgpt-codex/lib/extractedCoverage.nix`.

The `ai.*` HM module provides a unified interface that fans out shared AI-CLI
configuration to each capable enabled ecosystem (Claude, Codex, Copilot, Kimchi,
Kiro). It is NOT a thin wrapper — the gating semantics, default-setting
behavior, and fanout patterns are load-bearing and got bitten into production by
a silent no-op bug. Read this fragment before changing the gating.

### Codex checks the names its launcher uses

`packages/chatgpt-codex/extracted/` holds facts measured from the pinned binary
per platform (the `cli.globalFlags` fact here).
`packages/chatgpt-codex/extract/rules.nix` checks launcher flags from
`lib/launcher-flags.nix` against the root command's flags as reconciliation's
`uses`. `chatgpt-codex-extracted` reports a used flag removed from that command.
Other removed upstream names disappear from the extracted surface without an
acceptance ledger.

Stable feature names become typed directly from the sidecar; every other
maturity remains available through the boolean freeform table. Model slugs stay
strings because availability is account- and provider-dependent, and extracted
reasoning levels feed typed enums. The closed `--sandbox` and
`--ask-for-approval` value sets also feed their typed options directly; do not
restore parallel handwritten lists.

### There is no `ai.enable`

The `ai` module has **no master enable option**. Each per-CLI sub-enable is the
sole gate for that ecosystem's product output:

| Consumer sets               | What fires                                                          |
| --------------------------- | ------------------------------------------------------------------- |
| `ai.claude.enable = true`   | Claude package + claude fanout block                                |
| `ai.codex.enable = true`    | Codex package + guidance, skills, settings, agents, hooks fanout    |
| `ai.copilot.enable = true`  | github.com Copilot's repository files (devenv); no package          |
| `ai.kimchi.enable = true`   | Kimchi package + context, MCP, settings, skills, environment fanout |
| `ai.kiro.cli.enable = true` | Kiro package + kiro fanout block                                    |

`ai.kiro.enable` exists but is read-only: the factory derives it from the
launcher switch at `ai.kiro.cli.enable`. Generic code reads
`ai.<runtime>.enable`, sets a switch through `lib/ai/option-paths.nix`'s
`enable runtime` helper, and finds a per-runtime pool through its
`pool runtime surface` helper. Both read the record's `optionNamespaces` through
`lib/ai/app/optionNamespaces.nix`: `launcher` holds `package`, the launcher
pools (`environmentVariables`, `shell`) and a nested switch; `pools` holds every
other pool option and its `normalized` form. Kiro sets `launcher = ["cli"]`.
Copilot sets `pools = ["github"]` and reserves `launcher = ["cli"]`; it ships no
package, so it has no launcher, and its root `enable` stays the switch.

No runtime hands its files to an upstream `programs.<cli>` or devenv
integration: every one delivers through `ai.<runtime>.files`, so there is no
second enable to flip or to override. Claude asserts the exclusion, because its
upstream modules write the same files: `ai.claude.enable` beside Home Manager's
`programs.claude-code.enable` or devenv's `claude.code.enable` fails evaluation.

**Package installation is NOT per-factory work.**
`lib/ai/app/mkBackendTransform.nix` installs each enabled runtime's non-null
launcher package, lowering it to `home.packages` on Home Manager and `packages`
on devenv — the two option names being the whole reason it cannot live in a
factory without being written twice per runtime. A backend spec that says
nothing installs the selected launcher package; one that wraps its binary
supplies an `installPackage` callback taking the same arguments as `config`, on
the record or on one backend spec, which wins. Setting the launcher
`package = null` explicitly skips installation without disabling any generated
configuration; the transform does not call `installPackage` in that case. When
the resolved `ai.<runtime>.jail` enables a jail, the transform wraps that
finished launcher outermost and in place, one bubblewrap jail per name in the
record's `executables` (`lib/ai/jail/default.nix`); on a non-Linux host it
installs the plain launcher and warns on both backends. A setting that needs the
managed binary path or wrapper WARNS, not asserts, and only once the consumer
actually wrote it — the test is that setting's own option priority landing below
the bare declared default (1500), the same idiom `lib/ai/delivery-warnings.nix`
uses. A default-on feature (Kiro's `gitSshConfigWorkaround`, Codex's Home
Manager-only `pinDaemonToPackage`) stays silent at its default value and names
itself only once explicitly set. Kiro folds every inert setting into one warning
naming each option; Codex's `pinDaemonToPackage` gets the same treatment on its
own.

Kiro's launcher subtree is `ai.kiro.cli`: `package`, `environmentVariables`,
`jail`, `shell`, `extraPackages`, `native.settings`, `trustedMcpTools`,
`tweaks`, `features.<name>.enable`, `useFhsSandbox` and `v3`, plus the friendly
`backgroundExecution`, `codeToSpec`, `kvim`, `sandbox` and `workflows` switches.
Rollout names and typed `native.settings.chat.keybindings` keys come from the
extracted registry. Friendly workflows select the GA stock package and imply
their global client setting on Home Manager; Code-to-Spec also implies its
global setting there. Devenv warns when either requested global setting is
missing, and refuses explicit project-only writes of global keys. The
environment, jail and shell folds live at `cli.normalized.environmentVariables`,
`cli.normalized.jail` and `cli.normalized.shell`. All other normalized pools,
native agents, permissions, hooks, MCP, files and activation remain shared under
`ai.kiro`. There are no old-path aliases.
`ai.kiro.cli.enable = true; ai.kiro.cli.package = null;` keeps shared files
without installing a CLI.

The direction of that default is load-bearing. Installation used to be a
per-factory `home.packages` / `packages` write with no shared requirement, and
`claude` shipped with it missing from BOTH backends, visible on devenv as
`claude` silently resolving to whatever the developer had installed
user-globally. Silence now means "install the plain package", so the same
omission is inert rather than invisible. `checks/ai-fanout/module-eval.nix`'s
`every-runtime-installs-package` asserts a non-empty package list for every
runtime with a launcher on both backends under the unchanged defaults. Explicit
null is the consumer opt-out; it does not weaken the default-install invariant.

On devenv, the installation block also emits one PATH-provenance notice for each
enabled runtime with a non-null package. It derives the executable name from the
selected package, compares the shell's `command -v` result with
`$DEVENV_PROFILE/bin/<name>` after resolving symlinks, and warns if a
user-global or other shell install shadows the profile copy. Missing
profile/binary paths stay silent, and the standalone strict-mode notice always
exits zero. Disabled runtimes and explicit null package selections emit no
notice. Module fixtures execute the rendered command for every runtime; this
replaces the repository-only fail-hard `enterTest` loop.

Commands that must release state while an owner is disabled use
`activation.<key>.runWhenDisabled = true` outside its product gate. Codex's Home
Manager daemon selector does this. Every retired writer's ledger is forwarded
unconditionally through `legacyLedgers`, so the engine imports and drains copies
even when an owner is disabled at its first upgrade. The engine prunes before
native link checks; ordinary product files and commands remain gated. Keep a
configured directory unchanged for the activation that drains its old ledger,
then change it in a later generation.

### Why there's no master switch

The original design had `config = mkIf cfg.enable (mkMerge [...])` wrapping
everything, requiring BOTH `ai.enable = true` AND `ai.claude.enable = true` to
fan out. This caused a silent no-op: a consumer who set
`ai.claude.enable = true` without `ai.enable = true` got no fanout at all — the
upstream Claude module's options stayed at defaults, configuration was stored in
the option but never fanned out.

Surfaced 2026-04-07 during HITL integration. Root cause: the outer
`mkIf cfg.enable` gate was false.

Four fix options were considered; option (b) was chosen:

1. Move per-CLI fanout outside the mkIf (kept rest of gating)
2. **Drop `ai.enable` as a master switch entirely** ← chosen
3. Magic-default `ai.enable` from sub-options (opaque)
4. Document the requirement loudly with an assertion

Option (b) is the cleanest: redundant gates create silent failure modes. Each
option that looks like it should "do something" must actually do something. The
master switch added no information over the per-CLI enables.

Fix landed in commit f2e911c.

### Harness activation also stabilizes Git SSH

`ai.gitSshConfigWorkaround` defaults true. When any supported harness is
enabled, Home Manager contributes `programs.git.settings.core.sshCommand` and
devenv contributes `GIT_SSH_COMMAND`, both at `mkDefault` priority. The devenv
environment setting intentionally covers ordinary Git launched from the dev
shell as well as Git launched by a harness.

The shared command is a narrow wrapper around the packaged OpenSSH. It resolves
`~/.ssh/config`; when that symlink points into `/nix/store`, it passes the same
file explicitly through `ssh -F`. This avoids OpenSSH rejecting the store target
after a Linux user-namespace sandbox remaps its owner to `nobody`. Other config
locations use ordinary OpenSSH unchanged, preserving its normal ownership
checks. The wrapper does not replace the config with `/dev/null`, so Home
Manager host aliases and per-host identity routing remain active. Consumers can
set `ai.gitSshConfigWorkaround = false` or override either backend-native value.
The wrapper forces `BatchMode=yes` on both paths: agent-backed authentication
continues normally, while unavailable credentials fail instead of opening a
password dialog in an unattended harness session.

### Fanout data flow

The ai module fans out TWO kinds of configuration:

**Per-CLI options** (live inside `ai.{claude,codex,copilot,kimchi,kiro}.*`):

- `ai.claude.package` / `ai.codex.package` / `ai.kimchi.package` /
  `ai.kiro.cli.package` — package override. All four are installed by the shared
  backend transform unless set to `null`; github.com Copilot has no package.
  Three supply an `installPackage` callback that wraps the selected package when
  the runtime needs env or flag injection and installs it bare otherwise —
  wrapping is conditional for Kiro. Codex and Kimchi always wrap for their
  launch preflight checks, on both backends, isolated by the shared
  `lib/ai/launcher-preflight.nix`. `lib.ai.mkLauncher` execs the original
  package directly and flattens an earlier launcher through its
  `launcherPackage` passthru. The process environment each one bakes in is the
  builder's `launcherEnvironment`.
- `ai.kiro.cli.extraPackages` — store-backed tools added to Kiro's runtime PATH
  in both backends. It is Kiro-specific because it closes the Linux
  `buildFHSEnv` visibility gap; it remains independent of `ai.shell`, which
  selects an executable rather than supplying commands.
- `ai.kiro.cli.useFhsSandbox` — defaults true and keeps nixpkgs' Linux
  compatibility wrapper. False selects the configured package's pinned
  `passthru.unwrapped` payload in both backends; validation inspects the
  rollout-resolved package, so custom factories must preserve that route.
  Packages without it fail a named assertion. This is runtime-specific package
  selection, not a normalized sandbox pool.
- A custom Linux FHS package used with `trustedMcpTools` must expose both
  `passthru.unwrapped` and `passthru.withFhsPayload`. Otherwise the synthesized
  `/usr/bin/kiro-cli-chat` can shadow the outer trust wrapper, so the module
  rejects the configuration instead of silently losing the grant. Direct payload
  packages may declare `passthru.kiroFhsSandbox = false`; the overlay does this
  for darwin and pre-split nixpkgs.
- `ai.codex.native.settings` — typed stable keys plus a TOML-compatible native
  freeform tail. The module sets neither model nor reasoning effort unless the
  consumer declares one, leaving Codex's lower config layers or built-in
  defaults to supply them. Normalized reasoning effort lowers to
  `model_reasoning_effort` at default priority; explicit native values override
  it. Both backends deliver `config.toml` as a read-only store symlink: Home
  Manager always owns `${configDir}/config.toml`, and devenv writes the trusted
  project's `.codex/config.toml` when something is declared. Every Codex config
  writer writes a temporary beside the link's target, so an in-app save
  (`/model`, `/experimental`, `codex mcp add`, the trust prompt, `/hooks`) fails
  with "failed to persist config" and the link survives;
  `chatgpt-codex-readonly-config` holds that against the pinned binary. Devenv
  rejects provider, profile, notification, response-metadata, realtime-endpoint
  and telemetry keys that Codex ignores at project scope. MCP configuration is
  composed into either file through the same typed server pool. Stable security
  settings type `allow_login_shell`, `approval_policy` (including granular
  prompt categories), `approvals_reviewer`, `sandbox_mode`, and
  `sandbox_workspace_write`. `default_permissions` and named `permissions`
  profiles type inheritance, workspace roots, filesystem access and scoped
  paths, deny-glob scan depth, and network proxy/domain/socket policy. Codex
  merges entries under the same named permission profile across user and project
  config layers; both backends may therefore contribute to one policy without
  restating lower-layer roots. The older sandbox model and permission profiles
  remain mutually exclusive, so the module fails when both appear in one
  settings tree. At every launch, on both backends, the launcher's preflight
  runs `codex-permission-layers-notice` on each `.codex/config.toml` Codex would
  load from the launch directory and on
  `${CODEX_HOME:-$HOME/.codex}/config.toml`, warns when their models differ, and
  names the winning selector when the project is trusted and loaded. Selectors
  resolve low-to-high; tables alone do not select a model. Missing/unreadable
  files and malformed TOML stay silent. Profile names and inheritance graphs
  remain runtime-validated by Codex because config layers may contribute parents
  dynamically. The distinct whole-file `ai.codex.profiles.<name>` surface (a
  separate static `${configDir}/<name>.config.toml` user layer selected with
  `codex --profile <name>`) was removed 2026-09-19 as unreachable dead code; see
  the Settled bullet above. `projects.<path>.trust_level` is accepted only by
  Home Manager's user-global file for persistent trust: one entry per clone,
  since Codex resolves a linked worktree to its main checkout; an empty worktree
  entry does not revoke that trust, while an explicit worktree `trust_level`
  takes precedence. Devenv rejects it because a project cannot bootstrap the
  trust required to load its own `.codex/config.toml`. Devenv's opt-in
  `ai.codex.trustProjectForSession` instead adds a table-form
  `-c projects={...}` session override for the runtime `$DEVENV_ROOT` before the
  preflight. It leaves user config untouched and quiets the trust notice when
  that root is trusted. Set it in uncommitted `devenv.local.nix` for a local
  choice. Parent-folder trust does not cover child repositories; clone trust
  does cover linked worktrees. Without Home Manager, `~/.codex` is Codex's own
  and its trust prompt saves there. The same launch preflight runs
  `codex-project-trust-notice`, which warns when a readable project config will
  be ignored because nothing trusts the project, including when the user config
  is missing. It takes each directory's trust from the preflight's one
  `effectiveProjectDocMaxBytes` resolver run. Unreadable or malformed inputs
  stay silent, and the warning never changes the launch.
  `ai.codex.execpolicyRules.<name>` writes native Starlark to
  `<config-layer>/rules/<name>.rules` in both backends. It is intentionally
  separate from Markdown `ai.rules`, which remains durable AGENTS.md guidance.
  Home Manager reserves `execpolicyRules.default` because Codex appends accepted
  user allow-list decisions to `$CODEX_HOME/rules/default.rules`; other
  per-entry files remain declarative while that native mutation can coexist.
  Trusted project rules are declarative and may use `default` because Codex's
  native writer targets only the user layer.
- `ai.codex.agents.<name>` — a normalized agent record or a raw standalone TOML
  role file, delivered verbatim (not scanned for OAuth secrets);
  `ai.codex.agentsDir` expands `.toml` files into raw entries. A normalized
  record lowers into `ai.codex.native.agents.<name>` at `mkDefault`, a typed
  TOML record with required `name`, `description` and `developer_instructions`
  over a freeform TOML tail: `name` defaults to the key, and `description` and
  the instructions' text (a `source` is read) supply the other two. A
  native-only entry must set those two itself; an assertion names a missing one.
  Native keys (`model`, `sandbox_mode`, `skills.config`) go on the native record
  and win field by field. Home Manager emits `${configDir}/agents/<name>.toml`;
  devenv emits trusted-project `.codex/agents/<name>.toml`. Global concurrency,
  model/effort defaults, and interruption behavior live in the typed
  `ai.codex.native.settings.agents` table.
- `ai.codex.hooks.<Event>` — Codex-native matcher groups and command handlers,
  appended after portable `ai.hooks` groups and emitted in adjacent
  `hooks.json`. The handler extends the portable command handler, so the two
  share `command`, `timeout` and `type`; typed native additions include
  `commandWindows`, `statusMessage`, and `additionalContextLimit`, and a
  JSON-compatible tail remains for forward compatibility. Claude's and Codex's
  matcher groups both come from `lib.ai.hooks.mkMatcherBlockType`. Typed hooks
  cannot coexist with inline hook events in `ai.codex.native.settings.hooks` at
  one layer because Codex loads both additively and warns rather than applying
  normal config precedence; `hooks.state` may accompany either. Nix ownership
  does not make these managed hooks: Codex runs a user or project handler only
  while `hooks.state."<key>".trusted_hash` in user config or a session flag
  matches its current hash, and `/hooks` cannot record that into the Nix-owned
  config. So Nix derives the key and hash of every generated handler
  (`hookTrustFor`): Home Manager writes them into user `config.toml` beside any
  declared `hooks.state`, and devenv's launcher passes them as one
  `-c hooks.state={…}` flag, because Codex splits a `-c` key path at every dot
  and the keys are paths. devenv rejects `native.settings.hooks.state`, which
  Codex ignores in project config. `chatgpt-codex-hook-trust` compares keys and
  hashes with the pinned binary's `hooks/list`.
- `ai.codex.native.daemonSettings` — freeform JSON for the shared app-server
  daemon's `${configDir}/app-server-daemon/settings.json`, Home Manager only
  (devenv runs Codex with `--no-daemon` and rejects a value). Codex renames over
  that file when it saves it, so it is a staged `ro` JSON entry the files engine
  restores; `pinDaemonToPackage` defaults `updater.autoUpdateEnabled` to false.
- `ai.copilot.github.projectDir` — the project-native `.github` root used by
  devenv for context, rules and skills. It is declared identically in both
  backends so generated option discovery and types cannot drift, but only devenv
  has a project root. Home Manager therefore rejects a non-default override
  instead of silently interpreting it relative to `$HOME`; use the devenv module
  when this path needs customization.

**Cross-ecosystem options** (live at `ai.*` top level and fan out to each
enabled ecosystem whose native model preserves the option's semantics):

- `ai.settings.reasoningEffort` — the root portable `low` / `medium` / `high` /
  `xhigh` value. Every runtime that supports the normalized `settings` pool
  exposes the same field at `ai.<runtime>.settings.reasoningEffort`; a non-null
  per-runtime value wins for only that runtime, while null inherits the root
  through `resolveOverride`. Claude, Codex and Kimchi lower the resolved value
  to native `effortLevel`, `model_reasoning_effort` and harness
  `defaultThinkingLevel`, respectively. Kiro has no lossless target, so it
  declares no pool and warns when shared reasoning effort is requested;
  github.com Copilot reads no settings file and warns the same way. Values that
  only one runtime persists remain under that runtime's native settings. An
  explicit native effort key still has normal option priority over the derived
  normalized default, and a native null excludes that runtime from emission.
- `ai.skills` — attrset of name → directory path. Each enabled ecosystem gets
  its native representation. Codex uses user-global `$HOME/.agents/skills` in HM
  and repository-local `.agents/skills` in devenv; Claude, Kimchi, and Kiro use
  their established native directories. github.com Copilot gets real files under
  `<projectDir>/skills` on devenv through `mkSkillFiles` with `method = "ro"`.
  Home Manager has no repository to write and warns for explicit Copilot skill
  requests.
- `ai.agents` — only the normalized
  `{ description, instructions = { text | source; }; tools?; }` record; a string
  or path is a type error there (a path is coerced to a thrown message, because
  a bare submodule would import it as Nix). Each runtime's `ai.<runtime>.agents`
  replaces it per key, null withdraws it, and also takes a raw native file (text
  or path) that is written as is. `ai.<runtime>.agentsDir` expands its files
  into those raw entries at `mkDefault` (`agentsDirSuffixes`, `.md` by default;
  Kiro `.json` and `.md`, Codex `.toml`), so they blend with named entries; two
  files with one stem throw.

  The layering lives in `mkBackendTransform.nix`. A record that supplies
  `agentNativeType` (one native record's option type) and `agentTransformer`
  (`name: normalized → native attrset`) gets `ai.<runtime>.native.agents`; the
  builder splits raw entries out of the pool, keeps `normalized.agents` to
  normalized records, lowers each through the transformer with every field at
  its own `mkDefault` (a whole-record `mkDefault` would be discarded by one
  consumer field), and hands the callback raw files as `rawAgents` and native
  records as `nativeAgents`, so no runtime re-splits them; `mergedAgents` stays
  the normalized pool. A native entry with no normalized counterpart is a
  native-only agent, and so is one left behind when a per-runtime null withdraws
  the normalized record; one sharing a raw entry's key fails an assertion. A
  module that defaults a native entry must do it field by field too: Semble puts
  its portable record on `ai.<runtime>.agents` and only Kiro's own fields on
  `native.agents`. The transformer receives instructions with one text-source
  arm (`toNormalizedTextSource`), so Kiro's `prompt` takes it as is and Codex
  reads a `source`. Presence of the two fields is checked, never their values: a
  type built from `pkgs.formats.*` forces the factory's `pkgs` while modules are
  still importing.

  Without the native layer (Claude, Kimchi) the normalized pool keeps raw
  entries and the runtime renders the record directly: Claude frontmatter plus
  body, passing raw scalar data to the shared emitter; Kimchi Markdown omits
  `name:`. The shared renderer returns text, and treefmt formats the complete
  file; `parseCompare` compares parsed frontmatter values. `tools` uses Claude's
  tool names and renders a non-empty value as its frontmatter allowlist; `null`
  and `[]` both omit it. Codex, Kimchi and Kiro drop it, and the record's
  `surfaceSupport.agents` gap warns at the path that set it, naming the native
  remedy (Kimchi Markdown; `ai.kiro.native.agents.<name>.tools` and
  `permissions`); a native `tools` on the same agent silences it. Claude writes
  `.claude/agents/<name>.md` on both backends through `agent.renderFile`. A
  path-like raw entry — a Nix path, a store-path string such as a flake input's
  `"${src}/a.md"`, or a derivation, i.e. Home Manager's `isPathLike` — stays a
  file `source` (`agent.fileContent`, which tests `agent.isPathLike`) for
  Claude, Codex, Kimchi and Kiro; an `agentsDir` given as a store-path string
  yields store-string entries (any other absolute string becomes a path
  literal), so every writer must test `isPathLike`, never `builtins.isPath`.
  Kiro keeps a raw `.md` path's suffix and writes everything else as `.json`.
  Kimchi's agent files are the one Markdown surface a harness rewrites (the
  `/agents` commands), so they state `method = "ro"` and take the reconciler's
  default `0444` mode. Edit, Disable and Enable therefore fail for a declared
  agent instead of changing Nix-owned content; Create and Eject can still add an
  unowned sibling.

- `ai.hooks` — command-only matcher groups across the exact shared Claude/Codex
  lifecycle event set. Shared groups run before per-runtime groups for the same
  event. Matcher strings pass through, so consumers must stay within the regex
  subset understood by both runtimes. Non-portable events fail with a diagnostic
  and belong under `ai.claude.hooks` or `ai.codex.hooks`. Command packages with
  a `meta.mainProgram` or conventional `pname` resolve to their package
  executable; bare-file derivations remain direct output paths. Kimchi reads the
  same Claude shape from a trusted project's `.kimchi/hooks.json`, so devenv
  writes shared plus `ai.kimchi.hooks` groups there; PermissionRequest is not a
  Kimchi event and is omitted with a warning. Kimchi has no user-scope lifecycle
  file Home Manager can own, so its Home Manager row warns for shared `ai.hooks`
  and per-runtime `ai.kimchi.hooks` requests. Kiro's v3 trigger records remain
  native-only, but their `action.command` resolves a package through the same
  shared `commandType`. Delegate-routing contributes its reminder to native
  per-runtime hooks, preserving these backend exclusions; package details live
  in `packages/delegate-routing/docs/development.md`.
- `ai.context` — a typed `text`/`source` global baseline. Each runtime has the
  same content record plus `filename`; root content precedes runtime content
  when both are present. The strictly higher-priority definition supplies the
  effective content whichever field it targets, so a consumer `text` can
  override a package-default `source` and a forced `source` can override
  ordinary `text`; setting both at one priority fails. Same-priority `text`
  definitions concatenate, explicit content auto-enables the record, and
  `enable = false` omits it. Required records and enabled optional records must
  resolve to non-empty inline text or a source path; disabled records may retain
  content or remain empty without emitting an artifact. Auto-enable checks the
  priority-filtered inline definitions before `text.apply`, while a winning
  source is present without reading its contents; this avoids an enable/text
  evaluation cycle and preserves source-only IFD laziness. An explicit empty
  text definition can override a lower-priority default source, but the
  resulting empty record fails when it is enabled. Package prose belongs in the
  text-source factory's `defaultContent` argument, which installs each supplied
  field as an inner `mkDefault` definition; the enclosing `mkOption` default
  stays `{}` so a consumer definition cannot discard the package prose or make
  dormant prose explicit. The shared evaluation check rejects non-empty outer
  defaults on direct text-source submodule declarations reachable through the
  repository HM/devenv harnesses. Claude defaults to `CLAUDE.md`; Codex, Kiro,
  and Kimchi default to `AGENTS.md`. Copilot defaults to
  `copilot-instructions.md` beneath `ai.copilot.github.projectDir` on devenv; it
  contributes nothing to the shared AGENTS.md composer. Named Copilot rules
  remain independent instruction files, including always-on rules. The transform
  derives structural `hasMergedContext` metadata before composition, so a
  final-file replacement or disable does not read discarded source-backed
  root/runtime context.
- `ai.rules` — named Markdown rules. `inclusion` is a priority-ordered list of
  trigger kinds; `lib/ai/ai-common.nix:resolveInclusion` chooses the first kind
  the target runtime supports and fails when none match. Its one support table
  is the contract:

  | runtime | `always` | `auto` | `fileMatch` | `manual` |
  | ------- | -------- | ------ | ----------- | -------- |
  | Claude  | yes      | no     | yes         | no       |
  | Codex   | yes      | refs   | yes         | refs     |
  | Copilot | yes      | no     | yes         | no       |
  | Kimchi  | yes      | refs   | yes         | refs     |
  | Kiro    | yes      | yes    | yes         | yes      |

  `refs` means the trigger is supported only when the rule declares non-empty
  `references`.

Kiro's per-runtime `inclusion` remains a scalar native override; after
root/runtime replacement it becomes a one-item priority list for the shared
resolver. When the portable list is omitted, `matcher = null` defaults to
`["always"]` and a non-empty matcher defaults to `["fileMatch"]`. `fileMatch`
lowers the matcher to Claude `paths`, Kiro `fileMatchPattern`, Copilot
`applyTo`, and a Codex/Kimchi prose scope preamble. Codex and Kimchi write rules
alphabetically to AGENTS.md ahead of context, with trace comments. A `fileMatch`
rule that names `references` becomes a path-scoped index entry; `auto` and
`manual` become on-demand index entries and require references. `auto` also
requires a description. Rules default enabled; a per-runtime same-key rule with
`enable = false` suppresses an inherited root rule. Same-priority `text`
definitions concatenate, and enabled rules require non-empty text or a source
path. Generated Codex AGENTS.md content must fit `ai.codex.projectDocMaxBytes`
(32 KiB by default). The generated-file tree checks its built bytes in
`installCheckPhase`, so an oversized file fails the build. A raised limit is
also written to Codex's own `project_doc_max_bytes`, which Codex honors at
project scope, so the file the guard admits is the file Codex reads. On devenv
the key lands in the project's `.codex/config.toml`, which Codex applies only in
a trusted project, so an untrusted session still uses the user limit or Codex's
default. Every module-provided Codex launcher checks project documentation
locally, on Home Manager and devenv and in repos without devenv. The shared
`effectiveProjectDocMaxBytes` resolver reads system, user, profile,
trusted-project and session limits, and discovers the configured project root.
The preflight selects the first existing `AGENTS.override.md`, `AGENTS.md` or
configured fallback in each directory from root to cwd, and accounts for the
cumulative budget. Warnings name `project_doc_max_bytes` and
`ai.codex.projectDocMaxBytes`; a skipped project config raising the limit adds
the user-config trust remedy. Explicitly untrusted projects load no project
docs. The preflight is bounded to one second, swallows failures, consumes no
stdin and never writes stdout; the launcher execs Codex so its exit status
survives. It does not run `debug prompt-input`: that command creates a session
and starts network and MCP prewarming even without a model request. The flake
check calibrates local discovery against that prompt builder offline. The
shell-entry document-window notice and manual devenv prompt probe are gone. The
instructions-drift build check still requires the path-scoped index and
always-on rule markers within this repo's default 32 KiB window. A replacement
or disable suppresses the generated bytes before they are read. Consumer layer-1
or layer-2 replacements bypass the generated tree and its byte guard; launcher
warnings still inspect the local project documentation. Codex also rejects
`matcher = []` as ambiguous; use `null` when there is no file scope or a
non-empty list for `fileMatch` content.

- `ai.mcpServers` — typed MCP definitions merged with
  `ai.<ecosystem>.mcpServers`. Codex lowers the merged pool to native
  `[mcp_servers.<name>]` TOML tables in both backends. It reuses the common MCP
  renderer for package mode arguments, settings-derived environment, and runtime
  credential wrappers, then removes the JSON-only `type` discriminator.
  Codex-only authentication, readiness, timeout, environment-name, and tool
  approval fields live under each server's `codex` block and lower from camel
  case to native snake case. Literal `httpHeaders` are store-visible;
  `envHttpHeaders` and `bearerTokenEnvVar` name environment variables so secret
  values never enter generated TOML. `oauth.client_secret` has no such
  indirection upstream, so an assertion rejects it on both backends on every
  typed route into an `[mcp_servers.<name>.oauth]` table: each server's `codex`
  block, `native.settings.mcp_servers`, and
  `ai.codex.native.agents.<name>.mcp_servers`. Raw `ai.codex.files` content and
  raw `ai.codex.agents` TOML are not inspected. Direct
  `ai.codex.native.settings.mcp_servers` cannot be combined with either typed
  pool because their table ownership would be ambiguous. Credential-injecting
  `proxy.enable` entries lower at their declaration scope before pool merging: a
  used top-level declaration owns one shared managed proxy and only its
  credential-free client entry fans out; a runtime declaration owns its proxy
  directly. The MCP server key is also the managed-unit identity, so reused
  proxy-owner keys fail and direct owners must choose different keys. A
  top-level proxy inherited by no enabled capable runtime creates no unit.
- `ai.environmentVariables` — shared env vars, baked into the launcher wrapper
  of every harness that has one: **Codex, Kimchi and Kiro**. Codex joined on
  2026-08-10 when it gained a wrapper; its `shell_environment_policy` is a
  different thing and still is — that filters what SPAWNED commands inherit,
  while this pool configures the CLI process itself. Claude is the one
  exclusion: `ai.claude.native.settings.env` is its native equivalent and beats
  process env. Its managed launcher suppresses the inherited API-key descriptor
  for a selected inference backend and delivers selected intercepting proxy CA
  trust before startup, preserving the native extra-CA override. See
  [Network Proxy](../ai-proxy/ai-proxy.md).

  **Never reach for Home Manager session variables or devenv `env` to deliver a
  runtime variable** — not for Codex, not for anything. An earlier revision of
  this bullet advised exactly that, and it is the one thing this repo does not
  do: those write the user's shell, so the value also reaches the developer's
  own session and every other process in it. Wrappers are inherited across
  `fork`/`exec`, so a harness's children still see it. See `shell-option.md` §
  NEVER write the shell environment.

- `ai.proxy` is the shared network proxy; see
  `dev/fragments/ai-proxy/ai-proxy.md`.

- `ai.settings.inference` — a selection (`instance` of a registered proxy
  instance, with `clientKey` when it declares clients, or an external CPA
  `url` + `key`) pointing harnesses at a proxy. A runtime that lists `inference`
  in `surfaceSupport.settings.fields` consumes
  `ai.<runtime>.settings.inference`, whose fields default to the root's set
  fields (`mkDefault`) except the other form's once it switches forms, and
  consumes the resolved `normalized.settings.inference` through the selected
  backend's lowering; Claude and Codex do. See the `ai-inference` fragment.

Cross-ecosystem scalar defaults and package-generated per-entry fanouts use
`mkDefault` so explicit values at the same scope take precedence. Keyed pools
then apply per-runtime replacement across scopes; nullable pools use null
negation, while rules use `enable = false`. Context and hooks retain their
documented composition semantics.

### Per-pool capability gate

Every app record carries one `surfaceSupport` declaration. The shared
transformer uses it for the per-runtime option schema, keyed-pool merge,
delivery callback, and shell resolution. A per-runtime pool write that the
runtime cannot consume is therefore an unknown-option error. A ROOT pool value
stays portable and degrades to the neutral value for an incapable runtime.

Kimchi supports `agents`, `context`, `environmentVariables`, `hooks`,
`mcpServers`, `proxy`, `rules`, `settings`, `shell`, and `skills`. Its rules
share Codex's flat AGENTS.md handling: Home Manager writes the user harness
file, while devenv contributes keyed units to the single repository aggregate.

`sharedSurfaceOptions` in `sharedOptions.nix` is the registration of shared
fanout surfaces. Its keys declare root options and populate the read-only
internal `sharedSurfaces` list. A keyed root option uses `keyedOption` metadata
so delivery policy derives its keyed withdrawal list from the same declarations.
Every runtime's `surfaceSupport` maps a surface name to
`{backends?; fields?; gaps?; reason?;}`. For `settings`, `fields` lists the
normalized settings it consumes; names must exist in `normalizedSettingsType`,
and a `fields` declaration requires nonempty backends. Settings gaps may only
name listed fields, including conditional gaps with `when`; a gap on an unlisted
field would duplicate its default warning. An omitted field warns by default,
even when the runtime consumes other settings. Only listed fields resolve from
the root and runtime pools; unlisted normalized fields default to null. This
breaks out-of-tree records that declare `surfaceSupport.settings` without
`fields` (including `{}`): they must declare `fields` for every normalized
setting they consume. Presence defaults to both backends; `backends = []`
consumes nothing and declares no normalized runtime option. A non-empty backend
list keeps both backend option trees, even where delivery is unavailable.
Omitted surfaces warn with the generic reason.

`app/decompose.nix` derives warnings from those declarations, including for
third-party `mkRuntime` records. A surface the backend does not deliver warns
ONCE per runtime when anything is set for it, at the root, in the runtime's own
pool or on its public `normalized` option, with the record's reason; the line
names the first input set in that order (runtime pool, root, normalized) and
never tracks where a value came from. The normalized option defaults to the fold
of the other two, so it is checked only when neither earlier input holds the
requested surface or field, and `findFirst` never forces it once an earlier
input warns. `settings` instead warns once per unsupported populated field,
naming the first input that sets it, in the same order; declaring `settings`
without `fields` does not consume any field. Silencing it takes a visible record
edit with a reason, never a stub writer. A gap is one field a delivered surface
drops: a nonempty `path`, a reason and an optional `when` predicate. With `each`
it checks every keyed entry, root or runtime pool; without, it warns once for
the first input with a nonempty field at `path`, in runtime pool, root,
normalized order. Root values copied into the runtime pool name that pool,
matching surface warnings without tracking origin. Predicates and dynamic
reasons receive the backend, the runtime cfg and the entry's name, path and
value. Keyed runtime replacements and tombstones withdraw inherited entries
before warnings.

The `normalized.settings` fold supplies per-field defaults: defining only
`reasoningEffort` preserves the resolved `inference` endpoint.

`checks/ai-warnings` generates populated, empty and disabled probes from the
real runtime records, the evaluated shared-surface registry and both backends.
It covers every unavailable surface, declared-but-unavailable runtime option,
and static record gap, plus root and runtime pool set together to pin the one
line and a value set only on the normalized option; every supported cell gets a
control against the whole-surface unsupported warning. Samples must exist for
each shared surface and static gap path. A factory fixture pins runtime-only and
normalized-only gap requests, because no real record has a pool-reachable static
gap. Conditional and keyed-entry gaps retain explicit runtime/path cases, whose
exhaustiveness assertion names any uncovered record gap. Expected normalized
reasons come from the records, including dynamic reasons.

Policy rows derive normalized absence and static gaps from the records alongside
physical delivery and native diagnostics; they no longer choose normalized
delivery warnings or override their reasons. Package rule contributors consult
the record's backend reach before writing. Native diagnostics belong to runtime
factories. Transport-dependent MCP field warnings and final-file replacement
warnings remain generic in the shared reader.

Diagnostic units, policy input paths and the generated warning cases address
each per-runtime pool through the record's `optionNamespaces`, so a nested
launcher pool (`ai.kiro.cli.environmentVariables`) or pool namespace
(`ai.copilot.github.rules`) is diagnosed at the path a consumer wrote.

A context or rule unit that resolves for a runtime but lands in a file whose
final entry has `enable = false` warns too, root or per-runtime: the file option
that switched it off is the consumer's own, and the drop used to be silent (this
repository's Codex rules vanished behind `files."AGENTS.md".enable = false`).
The record's `contentTargets` callback names each unit's path from the same
bindings its delivery uses; for a shared AGENTS.md key the final entry is the
owner's and the message names the runtime whose public entry disabled it. Every
such warning has a per-runtime remedy, so it never repeats forever:
`ai.<runtime>.rules.<name>.enable = false` for a rule,
`ai.<runtime>.normalized.context = lib.mkForce null` for context (root and
runtime context compose, so `ai.<runtime>.context.enable = false` would not
withhold the root part). A file REPLACED with the consumer's own bytes
(`files.<path>.content.text = …`, or a `source`) drops the same units and warns
the same way. `generatedFiles.nix` detects replacement from the selected content
alternative and priority; Markdown and raw defaults are whole-content
definitions, while structured values retain generated siblings. A sibling-only
override (`method`, `executable`) keeps generated content and stays quiet.

### Assertion semantics

Fanout validation assertions live outside per-runtime enable gates so invalid
shared data cannot hide behind a disabled CLI. This includes the portable
hook-event vocabulary check. Package pool ownership is a separate provenance
check over both backend module trees. Managed MCP proxy ownership is another
separate check: `sharedOptions.nix` aggregates declaration scopes, rejects
reused unit keys, and validates only active owners. Runtime-specific
materialization assertions remain inside the enabled runtime's factory—for
example, Codex's `hooks.json` versus inline-hook ownership check.

### Other boundaries

- Packaging the pre-built claude-code binary —
  `packages/claude-code/packages/ai/claude-code/package.nix`.

### Config parity

Every option on the HM ai module must have a matching option on the devenv ai
module with the same semantics. If you add an option to one, add it to the other
in the same commit. Codex's exact generated option-name set is compared across
both backends by `checks/modules/options-doc.nix`. Runtime scope differences
belong in backend lowering, not divergent declarations. Two Codex options are
intentional exceptions: Home Manager's `pinDaemonToPackage` selects the shared
user daemon, which devenv bypasses; devenv's `trustProjectForSession` trusts its
runtime project root, while Home Manager declares persistent user-global
`native.settings.projects` trust instead. `ai.codex.execpolicyRules` is one
typed surface, with HM writing each `.rules` file into the user-global
`${configDir}` and devenv writing the project-local `.codex/rules/<name>.rules`
instead — Codex reads both layers natively.

### Final delivery seam

Every runtime stages generated files in `ai.<runtime>._generatedFiles`: content,
format, method and surface. The staging helper forwards them through
`ai.<runtime>.files` to the shared `ai.files` plan, preserving priorities.
Consumers override the final backend-root-relative path at layer 1. Entry-level
`enable = false` suppresses any content form; empty text is legal. Structured
values receive a default per leaf, so one consumer leaf preserves generated
siblings. Markdown and raw content receive a whole-content default, allowing a
replacement to discard composed sources unread. Codex's user context omits empty
generated content, with that decision deferred until replacement arbitration.

The runtime's one tree formats and checks generated bytes. `surface` selects
`agents`, `context`, `hooks`, `mcpServers`, `rules`, `settings` or `skills`.
Checks use replacing defaults between root all, root surface and runtime surface
tiers; the final value executes once per represented surface. Consumer layer-1
and layer-2 replacements bypass generated formatting and checks. The engine
chooses `symlink`, `ro` or `rw` from the stated method, owns copies
individually, and retires dropped paths. Its backend lowering is the sole native
sink writer. The devenv module also appends `ai.deliveredPaths` to treefmt
excludes.

The shared repository AGENTS.md composer remains the single layer-1 owner
`internal`; runtime overrides forward unclaimed. Agreeing content merges,
divergent content conflicts, and suppression wins over defaults. The composer
stages one Markdown copy, guarded by the contributing runtime limits, and keeps
its old ledger in `legacyLedgers`. Codex stages settings, agents, hooks, skills
and user context as links, execpolicy as `ro` raw copies on both backends, and
daemon settings as `ro` JSON on Home Manager only. Its ungated legacy
declarations cover both deleted copy writers. `activation.codex-daemon-select`
runs while disabled; `activation.codex-migrate-skill-links` runs before
`linkCheck` on both backends, with `after = []`.

Every runtime factory imports the layer-1 helper. Only staged entries feed
`lib/ai/app/generatedFiles.nix`, which supplies text and non-recursive source
from the generated tree, values per leaf, and recursive sources or `run` as
themselves. Every staged entry requires the tree: the engine adds its string
context to each delivered leaf after walking the source. Attaching that context
to the source before `readDir` would build the tree at evaluation. Ungated
`legacyLedgers` declarations and the engine's legacy drain remain for upgrades
from older generations. `ai.deliveredPaths` is declared by ai-module and lists
only enabled plan keys, with recursive trees excluded as `<key>/**`.

### Documentation parity is capability parity

Do not describe every top-level pool as mechanically reaching all five runtimes.
The shared option descriptions and generated README capability matrix must name
each registered runtime as a consumer or an intentional exclusion. In
particular, Codex's `shell_environment_policy` filters child-command inheritance
rather than setting the Codex process environment; a raw Codex agent is TOML,
never Markdown; and only the Claude/Codex lifecycle intersection belongs in
portable hooks.

`lib/options-doc.nix` evaluates both complete published module trees and
produces their CommonMark/JSON references. The old mdbook/NuschtOS site is gone,
but `checks/modules/options-doc.nix` deliberately builds both renderings so this
consumer-facing contract cannot become dead code. It compares every `ai.codex.*`
option name, checks the expected top-level surface, and verifies that
shared-pool descriptions discuss Codex. It also requires every runtime's native
file option under `ai.<runtime>.native` (`ai.kiro.cli.native` for Kiro) and
rejects the retired flat `nativeSettings`/`harnessSettings` names. Each guard
runs through a shell helper that names the option and the rendering it failed
on, and reports a jq or grep error as an error, so an unreadable rendering
cannot pass an absence guard. README.md remains generated from
`dev/generate.nix`; `checks/instructions/instructions-drift.nix` prevents its
checked-in capability matrix from diverging from that source.

### Verifying fanout works

From a consumer repo with the module imported:

```bash
nix eval --impure --json \
  '.#homeConfigurations."<host>".config.ai.deliveredPaths' \
  --apply 'paths: builtins.filter (n: builtins.match "[.]claude.*" n != null) paths'
# Should list .claude/settings.json, skills, agents, … if ai.claude.enable = true
```

`ai.deliveredPaths` covers every enabled plan path; `home.file` holds only the
`symlink` entries, so engine-owned copies such as `.claude.json` never appear
there.

If the list stays empty despite `ai.claude.enable = true`, the fanout is broken
— fix the module, not the consumer.

### Shared-pool is per-evaluation, NOT cross-backend

`lib/ai/sharedOptions.nix` declares cross-app pools (`ai.agents`, `ai.context`,
`ai.environmentVariables`, `ai.hooks`, `ai.mcpServers`, `ai.proxy`, `ai.rules`,
`ai.skills`). Both backend module trees import it, and `lib/ai/app/default.nix`
selects the one shared transform body per backend.

**The option declarations are shared. The values are NOT.**

HM and devenv run separate `evalModules` invocations with independent config
trees. A value set in the HM-imported copy of a module is visible only to HM's
eval. Devenv's eval has a completely separate `config.ai.skills` (etc.) that
doesn't see the HM contribution.

**Consequence for package modules outside `mkRuntime`** (including the
`mkSkillPackageModule` consumers): when a package contributes to `ai.skills` /
`ai.rules` / etc., the contribution MUST happen in the module's appropriate
backend sibling. If the content is HM-scope (personal user config), put it in
the HM module. If it's project-scope (devenv-only), put it in the devenv module.
Contributing in one and expecting the other to pick it up will silently fail —
the contribution just doesn't land in the other eval. A program option tree can
make enablement structural without changing that per-evaluation ownership.

AI CLI factories (`mkRuntime`) instead share one record-level `config` callback,
which receives `backend` for intentional scope differences. Package installation
and migration callbacks sit on the record too, and a backend spec may override
either; it cannot carry a delivery callback. Each backend still evaluates that
configuration independently; sharing code never shares option values.

Portable program integrations use `lib.ai.program.mkProgram`. One specification
declares the program name, its runtime capability set, and its nested option
tree. The factory projects that into `ai.programs.<name>` plus only the listed
`ai.programs.<name>.runtimes.<runtime>` paths. Runtime leaves are nullable and
resolve independently through `resolveOverride`: null inherits the portable
value and a non-null value wins. This is the scalar B4 contract, not keyed-pool
tombstone behavior. The program and runtime settings are plain option trees, not
submodule options. Whole-record `mkDefault` and `mkForce` apply to each portable
leaf independently and cannot override a runtime settings leaf. `runtimes` is
reserved for runtime overrides. These trees have no root options-doc entry;
their leaf entries remain documented.

The program implementation consumes only resolved per-runtime records and may
write `ai.<runtime>.<pool>` entries at `mkDefault` priority; it must never write
the root pools. A runtime-specific program `enable = false` is the runtime-list
replacement. For Semble's inherited MCP feature, an explicit runtime feature
value is more specific still; otherwise the runtime program value takes
precedence over an inherited portable feature value. Semble's CLI rule and named
agent are explicit portable opt-ins: a runtime program false retracts them, but
a runtime program true does not activate them. The program still must not set
`ai.<runtime>.enable`, because package/CLI activation remains an explicit
consumer choice.

Semble was the first factory consumer. Its single spec supports Claude, Codex,
and Kiro, and generates its named MCP, agent, and `semble` rule defaults in both
backend evaluations. The MCP agent and CLI rule use separate committed prompts.
Kiro alone can carry `mcpServers.semble` inside its named agent, so an
MCP-backed subagent with `mcp.enable = false` gets a server private to that
agent on Kiro and fails evaluation on Claude and Codex. The skill-package
factory now consumes the same primitive for stacked-workflows, with an
enable-only program spec that supports every registered runtime. The rule
composes into Claude and Codex's single always-loaded files and lets Kiro's
directory-native renderer write `semble.md`.

Semble also treats Codex's selected permission model as an integration boundary.
A selected Codex feature appends that runtime's effective Semble cache to the
hidden integration-root pool. Legacy `sandbox_mode = "workspace-write"` lowers
it to `sandbox_workspace_write.writable_roots`; a selected custom permission
profile lowers it to a direct `filesystem.<path> = "write"` rule. Home Manager's
cache family starts at `${config.xdg.cacheHome}/semble`; devenv's starts at
`${config.devenv.state}/semble-cache`. One resolved package uses that root.
Distinct runtime packages use package-keyed `variants/` subdirectories, receive
runtime-specific CLI aliases, and never share an incompatible customization
fingerprint. Launcher wrappers fix `SEMBLE_CACHE_LOCATION` for their own
variant; there is no consumer environment override. The convenience module does
not select a permission model. Read-only, unrestricted, built-in, or unselected
profiles get no writable-root contribution. An explicit filesystem rule at the
same path in the same emitted layer wins over the integration default, so that
layer can narrow or deny a contributed cache without disabling the owning
integration. Normal Codex precedence still applies across files: a
higher-precedence project layer can replace a lower user-layer rule.

Codex itself contributes the roots needed by its normal backend lifecycle when
the consumer selects either legacy `sandbox_mode = "workspace-write"` or a
custom named permission profile: Home Manager adds
`${config.xdg.cacheHome}/nix`; devenv adds the effective process user's Nix
cache. When `treefmt.enable`, devenv also adds
`${XDG_CACHE_HOME:-$HOME/.cache}/treefmt`; a disabled or absent treefmt module
adds nothing. The effective cache home follows `XDG_CACHE_HOME` when present and
otherwise uses its conventional `$HOME` fallback. Legacy workspace-write
additionally receives `${config.devenv.root}/.git` for compatibility. Named
permissions instead begin with devenv's automatically populated
`config.git.root`, inspect its `.git` directory or pointer file, and resolve
linked-worktree `gitdir` plus `commondir` metadata to the canonical shared
common Git directory. Absolute and relative metadata values are both supported,
and directory-form Git metadata follows its own `commondir` when present. The
resolver requires the Git directory's `HEAD` and the common directory's config
plus object database before emitting a rule, so an arbitrary directory named by
a forged pointer cannot become a broad write grant. The result is a direct
filesystem write rule, never a workspace root; a non-Git project emits no Git
rule. A parent used to write several worktrees remains explicit
repository-topology policy.

Enabled integrations can append their own runtime-owned state through the hidden
`ai.codex.internal._integration_writable_roots` pool. It is module plumbing
rather than a user setting, is omitted from generated option docs, and is folded
into native `sandbox_workspace_write.writable_roots` or the selected custom
permission profile only when Codex emits its config. The glab facets add the
effective `glab.configDir`, so a devenv consumer may point project-local glab at
an existing Home Manager `~/.config/glab-cli` and reuse its authentication
without another login. The default devenv glab directory remains project-local
state.

**Worked example — stacked-workflows skills.** Because a skills value set in one
backend is invisible to the other, the stacked-workflows package contributes its
`stack-*` skills from BOTH backend modules: the HM module installs them
user-global (`~/.claude/skills/stack-*`, ...) and the devenv module installs
them project-local — two separate, deliberate contributions, one per eval. A
2026-04 bug drove the lesson home: the skills were contributed from ONLY the HM
module while a shared devenv pool was expected to "pick them up", so devenv
consumers saw nothing while the HM contribution alone reached personal scope. It
was first scoped to the devenv module (commit `940ec54c`); the current design
re-adds the HM contribution as its own explicit, user-global emission, so both
backends now contribute (each via `lib/ai/mkSkillPackageModule`).

That helper declares `ai.programs.stacked-workflows.enable` through
`lib.ai.program.mkProgram`. A root true enables every supported runtime whose
pool exists in the current evaluation;
`ai.programs.stacked-workflows.runtimes.<runtime>.enable = false` retracts that
runtime's package contribution without affecting siblings. The removed top-level
package enable option has no alias. `stacked-workflows.gitPreset` is
deliberately not part of the program tree: it sets the `git.*` options, which
Home Manager delivers through `programs.git.settings` and devenv as a
repository-local include. It has no runtime meaning, so both backends expose the
same top-level companion instead of creating misleading runtime overrides.

**The contributions land PER RUNTIME, not on the root pool** — since 2026-08-14
the factory writes `ai.<runtime>.skills` and `ai.<runtime>.rules` for every
runtime whose module is present in the evaluation, filtered by option presence.
Each pool write follows the record's `optionNamespaces` and, when the caller
names its backend, the record's delivery support there; Copilot on Home Manager
receives no package skills or rules. Root `ai.skills` belongs to the consumer as
a portable default surface. Per-runtime null can now retract an inherited key,
but packages still do not write root values that fan out beyond their runtime
ownership. The `rootPoolViolations` provenance guard in
`checks/module-provenance/helpers.nix` enforces this by reading each root
option's `definitionsWithLocations`. The declaring module is exempt, which lets
`sharedOptions.nix` perform its root L1→L2 Dir reshape. So is
`packages/ai-module/lib/runtime.nix`, for `ai.activation`, `ai.files`,
`ai.claims`, `ai.legacyLedgers` and `ai.services` only: it re-publishes each
owner's layer-1 options at the root and sets `_file`, so its definitions report
the helper instead of the importing owner.

Two consequences to know before changing it. Consumer override keys are
`ai.<runtime>.skills.<name>` and `ai.<runtime>.rules.<name>`; package entries
use `mkDefault`, so an ordinary per-runtime consumer definition wins. Null
retracts a skill; `enable = false` retracts a rule. A same-key root entry
remains a portable default and is atomically replaced by the package's
per-runtime value. Two packages claiming that per-runtime key fail the
package-provenance guard (see `collision-semantics.md`).
