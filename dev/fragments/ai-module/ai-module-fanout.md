## ai Module Fanout Semantics

> **Last verified:** 2026-09-20 — upstream delivery aliases surviving content
> definitions so defaults and list ordering reach the host module unchanged.
>
> **Settled — do not relitigate.** Each of these records an approach that was
> TRIED and rejected, or a measurement that would otherwise be re-derived
> wrongly. Full lineage:
> `git show d1c28a21:dev/fragments/ai-module/ai-module-fanout.md`.
>
> - **Don't hardcode Copilot's instructions/rules destination to
>   `.github/instructions/`.** That resolves to `$HOME/.github/instructions/` on
>   Home Manager, a directory copilot-cli never reads — every named instruction
>   and rule was emitted and silently ignored. Route through
>   `ai.copilot.configDir` instead, like every other HM artifact this module
>   writes.
> - **Codex's beta permission model doesn't merge with legacy sandbox settings —
>   it overrides them, silently.** A layer carrying the beta model replaces the
>   legacy `sandbox_workspace_write` roots beneath it, and Nix evaluation can't
>   see across config layers to catch that. Measured with `codex sandbox`
>   0.146.1, where this repo's own former profile silently dropped the
>   module-contributed `~/.cache/nix` root — hence the hard assert rejecting the
>   combination rather than trying to reconcile it.
> - **`ai.kiro.agents.<name>` defaults `name` from the attribute key — don't
>   remove it as redundant.** Kiro ships two agent-schema parsers with different
>   requirements: the Rust CLI requires `name`, the Node/ACP parser treats it as
>   optional. The default satisfies both.

The `ai.*` HM module provides a unified interface that fans out shared AI-CLI
configuration to each capable enabled ecosystem (Claude, Codex, Copilot, Kimchi,
Kiro). It is NOT a thin wrapper — the gating semantics, default-setting
behavior, and fanout patterns are load-bearing and got bitten into production by
a silent no-op bug. Read this fragment before changing the gating.

### Codex extracted facts need reverse coverage

`packages/chatgpt-codex/extracted.json` is generated fact from the pinned
binary. `packages/chatgpt-codex/lib/extractedCoverage.nix` is the separate,
human-reviewed ownership decision. Never generate the second from the first:
`packages/chatgpt-codex/checks/chatgpt-codex-coverage.nix` intentionally fails
when a bump introduces a command, canonical flag, record field, feature
maturity, or config-key seam without an explicit Nix disposition.

Dynamic policy is still coverage. Stable feature names become typed directly
from the sidecar, non-stable names remain available through the boolean freeform
table, model slugs stay strings because availability is account- and
provider-dependent, and extracted reasoning levels feed typed enums. The closed
`--sandbox` and `--ask-for-approval` value sets also feed their typed options
directly; do not restore parallel handwritten lists.

### There is no `ai.enable`

The `ai` module has **no master enable option**. Each per-CLI sub-enable is the
sole gate for that ecosystem's product output:

| Consumer sets              | What fires                                                            |
| -------------------------- | --------------------------------------------------------------------- |
| `ai.claude.enable = true`  | claude fanout block + `programs.claude-code.enable = mkDefault true`  |
| `ai.codex.enable = true`   | Codex package + guidance, skills, settings, agents, hooks fanout      |
| `ai.copilot.enable = true` | copilot fanout block + `programs.copilot-cli.enable = mkDefault true` |
| `ai.kimchi.enable = true`  | Kimchi package + context, MCP, settings, skills, environment fanout   |
| `ai.kiro.enable = true`    | kiro fanout block + `programs.kiro-cli.enable = mkDefault true`       |

Where an upstream module exists, each per-CLI block implicitly flips its enable
via `mkDefault`, so consumers don't have to set enable twice. Codex and Kimchi
have no upstream modules. For CLIs that do have one, a consumer can still
override the corresponding `programs.<cli>.enable` explicitly.

**Package installation is NOT per-factory work.**
`lib/ai/app/mkBackendTransform.nix` installs a package for every enabled
runtime, lowering it to `home.packages` on Home Manager and `packages` on devenv
— the two option names being the whole reason it cannot live in a factory
without being written twice per runtime. A backend spec that says nothing
installs the plain `cfg.package`; one that wraps its binary supplies an
`installPackage` callback taking the same arguments as `config`;
`installPackage = null` opts out.

The direction of that default is load-bearing. Installation used to be a
per-factory `home.packages` / `packages` write with no shared requirement, and
`claude` shipped with it missing from BOTH backends — masked on Home Manager,
where upstream's `programs.claude-code` installs the package anyway, and visible
on devenv only as `claude` silently resolving to whatever the developer had
installed user-globally. Silence now means "install the plain package", so the
same omission is inert rather than invisible.

`claude` on Home Manager is the sole `installPackage = null` in the repo:
upstream already installs it there, and a second path to the same `bin/claude`
in one profile fails activation with a `buildEnv` conflicting-subpath error.
`checks/ai-fanout/module-eval.nix`'s `every-runtime-installs-package` pins each
runtime's delivery channel per backend, so that exemption cannot silently widen.

The one bounded exception is `migrationConfig`: ownership-safe retirement may
run outside the enable gate when the generation that disables a runtime must
remove files recorded by an older implementation. A retirement is not a
mechanism — it is an `own` target that declares NO units, so the ordinary
retraction removes what the previous generation's ledger recorded and then drops
the ledger, which is what makes it inert afterwards and what keeps it from
emitting product content. Kiro's one-shot steering-copy retirement is the
current sole caller, and on Home Manager it is a PAIR of entries: the prune
phase deletes the real files before `checkLinkTargets`, the write phase unlinks
the drained ledger. It derives the old target from the current `configDir`, so a
custom directory must remain unchanged for that retirement generation; change or
remove it only after one activation/shell entry has drained the old ledger.

### Why there's no master switch

The original design had `config = mkIf cfg.enable (mkMerge [...])` wrapping
everything, requiring BOTH `ai.enable = true` AND `ai.claude.enable = true` to
fan out. This caused a silent no-op: a consumer who set
`ai.claude.enable = true` without `ai.enable = true` got no fanout at all —
`programs.claude-code` options stayed at defaults, configuration was stored in
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

- `ai.claude.package` / `ai.codex.package` / `ai.copilot.package` /
  `ai.kimchi.package` / `ai.kiro.package` — package override. All five are
  installed by the shared backend transform. Four supply an `installPackage`
  callback that wraps the selected package when the runtime needs env or flag
  injection and installs it bare otherwise — wrapping is conditional, not
  automatic (`wrapPackage.nix` returns the bare package when `wrapArgs == []`).
  `ai.claude.package` additionally feeds `programs.claude-code.package`, which
  is what installs it on Home Manager.
- `ai.kiro.extraPackages` — store-backed tools added to Kiro's runtime PATH in
  both backends. It is Kiro-specific because it closes the Linux `buildFHSEnv`
  visibility gap; it remains independent of `ai.shell`, which selects an
  executable rather than supplying commands.
- `ai.kiro.useFhsSandbox` — defaults true and keeps nixpkgs' Linux compatibility
  wrapper. False selects the configured package's pinned `passthru.unwrapped`
  payload in both backends; validation inspects the rollout-resolved package, so
  custom factories must preserve that route. Packages without it fail a named
  assertion. This is runtime-specific package selection, not a normalized
  sandbox pool.
- A custom Linux FHS package used with `trustedMcpTools` must expose both
  `passthru.unwrapped` and `passthru.withFhsPayload`. Otherwise the synthesized
  `/usr/bin/kiro-cli-chat` can shadow the outer trust wrapper, so the module
  rejects the configuration instead of silently losing the grant. Direct payload
  packages may declare `passthru.kiroFhsSandbox = false`; the overlay does this
  for darwin and pre-split nixpkgs.
- `ai.codex.nativeSettings` — typed stable keys plus a TOML-compatible native
  freeform tail. Its model defaults to `gpt-6-astra` and reasoning effort to
  `xhigh` on both backends. Explicit native values override these defaults;
  normalized reasoning effort also overrides the native option default. Setting
  either native key to null omits it, allowing Codex's lower config layers or
  runtime defaults to supply it. Named config profiles retain null defaults so
  they do not pin a model or effort implicitly. Home Manager reconciles exact
  declared leaves into a writable `${configDir}/config.toml`; devenv writes a
  statically Nix-owned trusted-project `.codex/config.toml`. An empty first HM
  generation is a no-op, while an empty later generation uses the ownership
  manifest to remove formerly managed leaves without deleting native state.
  Devenv rejects provider, profile, notification, and telemetry keys that Codex
  documents as ignored at project scope. The backend ownership difference is
  deliberate: Codex's user-level trust prompt writes ad-hoc
  `projects.<path>.trust_level` entries into the same file through
  `config/batchWrite`, while no project-local writer has been observed. A
  versioned XDG-state manifest tracks Nix-owned leaf paths so activation can
  reassert and retire them while preserving unknown/native siblings, including
  siblings inside `projects`, `features`, and `mcp_servers`. MCP configuration
  is composed into that shared user file or the static project file through the
  same typed server pool. Stable security settings type `allow_login_shell`,
  `approval_policy` (including granular prompt categories),
  `approvals_reviewer`, `sandbox_mode`, and `sandbox_workspace_write`.
  `default_permissions` and named `permissions` profiles type inheritance,
  workspace roots, filesystem access and scoped paths, deny-glob scan depth, and
  network proxy/domain/socket policy. Codex merges entries under the same named
  permission profile across user and project config layers; both backends may
  therefore contribute to one policy without restating lower-layer roots. The
  older sandbox model and permission profiles remain mutually exclusive, so the
  module fails when both appear in one settings tree and consumers must not put
  legacy `sandbox_mode` in another loaded layer. Profile names and inheritance
  graphs remain runtime-validated by Codex because config layers may contribute
  parents dynamically. `ai.codex.profiles.<name>` is a distinct, still locked
  surface: it uses the same typed/freeform settings schema and would emit a
  separate static `${configDir}/<name>.config.toml` user layer selected with
  `codex --profile <name>`. Home Manager links that whole file directly. Codex
  resolves named profiles only from user CODEX_HOME, so devenv cannot place an
  inert copy beside project config; instead a pre-shell task materializes the
  repository-declared store file into CODEX_HOME. The task tracks ownership by
  Git common directory, serializes concurrent shell entries with a repository
  lock, updates and prunes only its own symlinks, accepts an identical
  externally managed file, and rejects conflicting content before changing any
  artifact. This keeps the declaration repository-scoped without changing
  CODEX_HOME and forking authentication/session state.
  `projects.<path>.trust_level` is accepted only by Home Manager's user-global
  file: devenv rejects it because a project cannot bootstrap the trust required
  to load its own `.codex/config.toml`. `ai.codex.execpolicyRules.<name>` writes
  native Starlark to `<config-layer>/rules/<name>.rules` in both backends. It is
  intentionally separate from Markdown `ai.rules`, which remains durable
  AGENTS.md guidance. Home Manager reserves `execpolicyRules.default` because
  Codex appends accepted user allow-list decisions to
  `$CODEX_HOME/rules/default.rules`; other per-entry files remain declarative
  while that native mutation can coexist. Trusted project rules are declarative
  and may use `default` because Codex's native writer targets only the user
  layer.
- `ai.codex.agents.<name>` — the semantic agent record plus a freeform `codex`
  TOML extension. Home Manager emits `${configDir}/agents/<name>.toml`; devenv
  emits trusted-project `.codex/agents/<name>.toml`. The filename stem supplies
  native `name`, while `description` and `instructions` lower to the two other
  required native fields. Reserved core fields cannot be redefined in `codex`.
  Global concurrency, model/effort defaults, and interruption behavior live in
  the typed `ai.codex.nativeSettings.agents` table.
- `ai.codex.hooks.<Event>` — Codex-native matcher groups and command handlers,
  appended after portable `ai.hooks` groups and emitted in adjacent
  `hooks.json`. Typed native additions include `commandWindows`,
  `statusMessage`, and `additionalContextLimit`; a JSON-compatible tail remains
  for forward compatibility. Typed hooks cannot coexist with inline
  `ai.codex.nativeSettings.hooks` at one layer because Codex loads both
  additively and warns rather than applying normal config precedence. Nix
  ownership does not make these native-policy hooks: Codex still requires
  `/hooks` review and hash-based trust before user/project handlers run.
- `ai.copilot.projectDir` — the project-native `.github` root used by devenv for
  context, rules, agents, and skills. It is declared identically in both
  backends so generated option discovery and types cannot drift, but only devenv
  has a project root. Home Manager therefore rejects a non-default override
  instead of silently interpreting it relative to `$HOME`; use the devenv module
  when this path needs customization.

**Cross-ecosystem options** (live at `ai.*` top level and fan out to each
enabled ecosystem whose native model preserves the option's semantics):

- `ai.settings.reasoningEffort` — the root portable `low` / `medium` / `high` /
  `xhigh` value. Every runtime exposes the same field at
  `ai.<runtime>.settings.reasoningEffort`; a non-null per-runtime value wins for
  only that runtime, while null inherits the root through `resolveOverride`.
  Claude and Codex lower the resolved value to native `effortLevel` and
  `model_reasoning_effort`; runtimes without a lossless lowering retain the
  normalized value without emitting a native key. Values that only one runtime
  persists remain under that runtime's `nativeSettings`. An explicit native
  Claude/Codex effort key still has normal option priority over the derived
  normalized default, and a native null excludes that runtime from emission.
- `ai.skills` — attrset of name → directory path. Each enabled ecosystem gets
  its native representation. Codex uses user-global `$HOME/.agents/skills` in HM
  and repository-local `.agents/skills` in devenv; Claude, Copilot, Kimchi, and
  Kiro use their established native directories.
- `ai.agents` — either legacy Markdown/path entries for Claude and Copilot or a
  portable `{ description, instructions, tools?, codex? }` record. Semantic
  records render Claude/Copilot frontmatter plus body and Codex standalone TOML.
  The optional `tools` list uses Claude and Copilot's shared tool names and
  renders a non-empty value as their comma-separated frontmatter allowlist;
  `null` and `[]` both omit the header. Codex deliberately omits it because its
  standalone agent format has no equivalent field. Codex fails loudly on a
  legacy raw entry instead of pretending Markdown is a valid agent config.
  Legacy Nix paths stay path-valued for Claude's native option but are read into
  text for Copilot's file writer. Kiro remains excluded, but NOT because its
  agents are untyped JSON — `ai.kiro.agents` is a typed record modelling Kiro's
  v3 agent schema, and its shape overlaps this intersection fine. The blocker is
  the tool VOCABULARY: this pool's `tools` carries Claude/Copilot tool names
  (`Bash`, `Read`) while Kiro takes capability tags (`shell`, `read`, `@mcp`),
  so lowering needs a translation table, not a pass-through. Add one and the
  exclusion can be revisited.
- `ai.hooks` — command-only matcher groups across the exact shared Claude/Codex
  lifecycle event set. Shared groups run before per-runtime groups for the same
  event. Matcher strings pass through, so consumers must stay within the regex
  subset understood by both runtimes. Non-portable events fail with a diagnostic
  and belong under `ai.claude.hooks` or `ai.codex.hooks`. Command packages with
  a `meta.mainProgram` or conventional `pname` resolve to their package
  executable; bare-file derivations remain direct output paths. Kiro's v3
  trigger records remain native-only.
- `ai.context` — a typed `text`-XOR-`source` global baseline. Each runtime has
  the same content record plus `filename`; root content precedes runtime content
  when both are present. Claude defaults to `CLAUDE.md`; Codex, Kiro, and Kimchi
  default to `AGENTS.md`; Copilot defaults to `copilot-instructions.md`. Copilot
  emits normalized context only on devenv because its live surface is the
  repository consumed by github.com, not copilot-cli's user home. The transform
  derives structural `hasMergedContext` metadata before composition, so a
  final-file replacement or tombstone does not read discarded source-backed
  root/runtime context.
- `ai.rules` — named Markdown rules. Codex appends these alphabetically to its
  AGENTS.md after context with trace comments. `matcher = null` means always-on;
  non-empty glob lists lower to Claude `paths`, Kiro `fileMatchPattern`, Copilot
  `applyTo`, and a Codex prose scope preamble. Kiro alone retains native
  `manual`/`auto` inclusion overrides. After B7 arbitration, a surviving inline
  Codex AGENTS.md must fit `ai.codex.projectDocMaxBytes` (32 KiB by default), or
  evaluation fails with a final-file diagnostic. A replacement or tombstone
  suppresses the generated bytes before they are read; a surviving store-backed
  `source` stays lazy and is therefore not size-checked at eval. Codex also
  rejects `matcher = []` as ambiguous; use `null` for always-on content or a
  non-empty list for scoped content.
- `ai.mcpServers` — typed MCP definitions merged with
  `ai.<ecosystem>.mcpServers`. Codex lowers the merged pool to native
  `[mcp_servers.<name>]` TOML tables in both backends. It reuses the common MCP
  renderer for package mode arguments, settings-derived environment, and runtime
  credential wrappers, then removes the JSON-only `type` discriminator.
  Codex-only authentication, readiness, timeout, environment-name, and tool
  approval fields live under each server's `codex` block and lower from camel
  case to native snake case. Literal `httpHeaders` are store-visible;
  `envHttpHeaders` and `bearerTokenEnvVar` name environment variables so secret
  values never enter generated TOML. Direct
  `ai.codex.nativeSettings.mcp_servers` cannot be combined with either typed
  pool because their table ownership would be ambiguous. Credential-injecting
  `proxy.enable` entries lower at their declaration scope before pool merging: a
  used top-level declaration owns one shared managed proxy and only its
  credential-free client entry fans out; a runtime declaration owns its proxy
  directly. The MCP server key is also the managed-unit identity, so reused
  proxy-owner keys fail and direct owners must choose different keys. A
  top-level proxy inherited by no enabled capable runtime creates no unit.
- `ai.lspServers` — typed LSP definitions, translated to Claude, Copilot, and
  Kiro native config. Codex is deliberately excluded: its current public config
  reference and pinned CLI expose no LSP-server registration surface, so
  pretending to fan out this pool would silently discard the declaration.
- `ai.environmentVariables` — shared env vars, baked into the launcher wrapper
  of every harness that has one: **Codex, Copilot, Kimchi and Kiro**. Codex
  joined on 2026-08-10 when it gained a wrapper; its `shell_environment_policy`
  is a different thing and still is — that filters what SPAWNED commands
  inherit, while this pool configures the CLI process itself. Claude is the one
  exclusion: it has no wrapper here, and `ai.claude.nativeSettings.env` is its
  native equivalent.

  **Never reach for Home Manager session variables or devenv `env` to deliver a
  runtime variable** — not for Codex, not for anything. An earlier revision of
  this bullet advised exactly that, and it is the one thing this repo does not
  do: those write the user's shell, so the value also reaches the developer's
  own session and every other process in it. Wrappers are inherited across
  `fork`/`exec`, so a harness's children still see it. See `shell-option.md` §
  NEVER write the shell environment.

Cross-ecosystem scalar defaults and package-generated per-entry fanouts use
`mkDefault` so explicit values at the same scope take precedence. Keyed pools
then apply per-runtime replacement/null negation across scopes; context and
hooks retain their documented composition semantics.

### Per-pool capability gate

Every app record carries one `supportedPools` list. The shared transformer uses
it for the per-runtime option schema, keyed-pool merge, callback fanout, and
shell resolution. A per-runtime pool write that the runtime cannot consume is
therefore an unknown-option error. A ROOT pool value stays portable and degrades
to the neutral value for an incapable runtime.

Kimchi is the sharp example: it supports `context`, `environmentVariables`,
`mcpServers`, `settings`, and `skills`, but not `rules`. Consequently root
`ai.rules` remains valid when Kimchi is enabled, while `ai.kimchi.rules` and
`ai.kimchi.rulesDir` do not exist. Capability tests pair every eval-failure
assertion with a supported-runtime positive control so harness failure cannot
masquerade as correct exclusion.

A non-empty ROOT request for an excluded pool is SILENT — no assertion, and no
activation warning either. The remedy a warning would ask for does not exist:
`ai.kimchi.rules` is an unknown option by design, so nothing the consumer can
write would silence it and it would repeat on every activation forever. The
exclusion is recorded in the pool's option description and in the delivery
matrix instead. A PER-RUNTIME request a backend cannot deliver does warn
(`lib/ai/delivery-warnings.nix`), because that one the consumer wrote directly
and can delete.

### Assertion semantics

Fanout validation assertions live outside per-runtime enable gates so invalid
shared data cannot hide behind a disabled CLI. This includes the portable
hook-event vocabulary check. Package pool ownership is a separate provenance
check over both backend module trees. Managed MCP proxy ownership is another
separate check: `sharedOptions.nix` aggregates declaration scopes, rejects
reused unit keys, and validates only active owners. Runtime-specific
materialization assertions remain inside the enabled runtime's factory—for
example, Codex's semantic-agent requirement and its `hooks.json` versus
inline-hook ownership check.

### Other boundaries

- The package wrapping (Bun runtime) for claude-code — handled in
  `packages/claude-code/packages/ai/claude-code/package.nix` at overlay level.

See the backlog item "ai.claude.\* full passthrough" for the ongoing work to
expose more `programs.claude-code.*` options via `ai.claude.*`.

### Config parity

Every option on the HM ai module must have a matching option on the devenv ai
module with the same semantics. If you add an option to one, add it to the other
in the same commit. Codex's exact generated option-name set is compared across
both backends by `checks/modules/options-doc.nix`. Runtime scope differences
belong in backend lowering, not divergent declarations: `ai.codex.profiles` is
one typed surface, with HM linking its user-global files and devenv
materializing the same whole-file layers from repository declarations into the
native user lookup location.

### Final delivery seam

Every runtime declares `ai.<runtime>.files`; there is deliberately no root
`ai.files`. Keys are non-empty normalized relative paths interpreted against the
backend root (HOME for Home Manager, project root for devenv). An entry
DESCRIBES a file rather than lowering one: `content` carries the bytes,
`facts.{harnessWrites,symlinkReadable}` carry what the CLI does with the path,
and `entry` / `ledger` name the writer that materializes it when it is not a
symlink. `null` suppresses a generated entry, and it absorbs at equal priority
so a tombstone still wins over a description.

`content` is a TAGGED sum (`lib.types.attrTag`), not a pair of nullable
siblings: exactly one of `text`, `source`, `value` (structured, rendered by
`format`) or `run` (a body that writes the file when the writer runs). The tag
is what makes the text/source exclusion a type rather than a hand-rolled check,
and what lets priority apply to the bytes ALONE.

That is the part most likely to be remembered wrongly, because it replaced a
whole-entry contract:

- a generator contributes `content = lib.mkDefault {text = …;}` and leaves every
  sibling field at ordinary priority, so a consumer changes HOW a file lands
  (`method`, `facts`, `mode`) without restating WHAT is in it;
- a whole-entry `mkDefault` is the opposite and was the bug: `filterOverrides`
  runs before `type.merge`, so any consumer definition at priority 100 discards
  the generated entry outright and the survivor has no content at all;
- a `value` document must NOT be defaulted as a whole either.
  `content = mkDefault {value = …;}` and `content.value = mkDefault {…}` both
  lose every generated leaf the moment a consumer defines one of its own —
  measured on the real type. A document contributes its leaves at ordinary
  priority, or one `mkDefault` per LEAF.

How a file lands is a METHOD — `symlink`, `copy-ro`, `shared`, `upstream` —
resolved by `ai.<runtime>.methodFor` from the facts, or stated per file as the
light exception. A runtime normally states facts; upstream delegation explicitly
states its method and sink. Reasons belong in comments.

The graph is one-way: normalized pools compose, runtime routing chooses a
target, the target renderer emits final bytes into `ai.<runtime>.files`, and the
delivery router (`lib/ai/deliver.nix`) plus one adapter per backend
(`lib/ai/adapters/`) lower surviving entries — the only code allowed to write
`home.file`, `home.activation`, devenv `files`, `tasks` or `enterTest`. Claude
context/rules, Codex user AGENTS.md, Copilot's repository context/instructions,
Kimchi harness AGENTS.md, and Kiro Home Manager context/steering all use the
runtime maps. Repository-local Codex/Kiro AGENTS.md retains one
divergence-checking owner and enters the same architecture through hidden
`ai.internal.files`, never through competing runtime writers. Public Codex/Kiro
entries for a shared target arbitrate inside that owner before its single native
sink: equal entries deduplicate, divergence fails, an ordinary entry replaces
the generated default, and null suppresses it.

It is a delivery description, not a universal file abstraction. Secret-bearing
values and runtime state keep their existing typed lifecycle owners, and a
surface another module owns is DESCRIBED here — `method = "upstream"` plus the
`sink` that owns it — rather than written here. The router aliases the surviving
content definitions, including their priorities, instead of copying the merged
value: copying strips `mkDefault` and breaks ordinary upstream overrides. The
suppressible entry type preserves submodule option metadata for that alias.
Definitions combine through `mkMerge` below each adapter's literal hosted root,
so the host retains its own deep-merge and list-ordering semantics. Dynamic
top-level roots remain forbidden because they recurse during option collection.
Skills go through the map now: one entry per tree, expanded by Home Manager
natively and walked by the router for devenv. Kiro steering uses ordinary
symlinks after live 2.18.1 spikes confirmed startup discovery and same-session
replacement reload in both global and project layouts; Kiro hooks stay real-file
reconciled (`lib/ai/own.nix`, a `dir` target) because hook symlink behavior was
not part of that result — the v3 scan keeps only `isFile()` entries. An
enable-independent one-shot retirement, the same reconciler with a target that
declares nothing, drains only the steering copies a legacy ledger records and
then removes it.

### Documentation parity is capability parity

Do not describe every top-level pool as mechanically reaching all five runtimes.
The shared option descriptions and generated README capability matrix must name
each registered runtime as a consumer or an intentional exclusion. In
particular, Codex has no native LSP registry; its `shell_environment_policy`
filters child-command inheritance rather than setting the Codex process
environment; legacy Markdown agents cannot become native Codex TOML; and only
the Claude/Codex lifecycle intersection belongs in portable hooks.

`lib/options-doc.nix` evaluates both complete published module trees and
produces their CommonMark/JSON references. The old mdbook/NuschtOS site is gone,
but `checks/modules/options-doc.nix` deliberately builds both renderings so this
consumer-facing contract cannot become dead code. It compares every `ai.codex.*`
option name, checks the expected top-level surface, and verifies that
shared-pool descriptions discuss Codex. README.md remains generated from
`dev/generate.nix`; `checks/instructions/instructions-drift.nix` prevents its
checked-in capability matrix from diverging from that source.

### Verifying fanout works

From a consumer repo with the module imported:

```bash
nix eval --impure --json \
  '.#homeConfigurations."<host>".config.programs.claude-code.enable'
# Should be true if ai.claude.enable = true
```

If the option stays false despite `ai.claude.enable = true`, the fanout is
broken — fix the module, not the consumer.

### Shared-pool is per-evaluation, NOT cross-backend

`lib/ai/sharedOptions.nix` declares cross-app pools (`ai.skills`, `ai.rules`,
`ai.mcpServers`, `ai.lspServers`, `ai.environmentVariables`, `ai.agents`,
`ai.hooks`, `ai.context`). It's imported by BOTH `hmTransform.nix` and
`devenvTransform.nix`.

**The option declarations are shared. The values are NOT.**

HM and devenv run separate `evalModules` invocations with independent config
trees. A value set in the HM-imported copy of a module is visible only to HM's
eval. Devenv's eval has a completely separate `config.ai.skills` (etc.) that
doesn't see the HM contribution.

**Consequence for package modules outside `mkAiApp`** (including the
`mkSkillPackageModule` consumers): when a package contributes to `ai.skills` /
`ai.rules` / etc., the contribution MUST happen in the module's appropriate
backend sibling. If the content is HM-scope (personal user config), put it in
the HM module. If it's project-scope (devenv-only), put it in the devenv module.
Contributing in one and expecting the other to pick it up will silently fail —
the contribution just doesn't land in the other eval. A program option tree can
make enablement structural without changing that per-evaluation ownership.

This is a different discipline from the AI CLI factories (`mkAiApp`), which have
structural `hm = { config = …; }` / `devenv = { config = …; }` blocks that force
per-backend separation by construction. Plain modules have no such guardrail —
authors must decide scope consciously.

Portable program integrations use `lib.ai.program.mkProgram`. One specification
declares the program name, its runtime capability set, and its nested option
tree. The factory projects that into `ai.programs.<name>` plus only the listed
`ai.<runtime>.programs.<name>` paths. Runtime leaves are nullable and resolve
independently through `resolveOverride`: null inherits the portable value and a
non-null value wins. This is the scalar B4 contract, not keyed-pool tombstone
behavior.

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
Kiro alone can carry `mcpServers.semble` inside its named agent, so
`mcp.rootExposure = false` is rejected for other runtimes and without a matching
MCP-backed Kiro agent. The skill-package factory now consumes the same primitive
for stacked-workflows, with an enable-only program spec that supports every
registered runtime. The rule composes into Claude and Codex's single
always-loaded files and lets Kiro's directory-native renderer write `semble.md`.

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
otherwise uses its conventional `$HOME` fallback. The locked whole-file profile
materializer exits before creating its state directory when it has neither
desired profiles nor an existing ownership manifest. Codex therefore receives no
broad grant over the XDG state parent holding every repository's profile state.
Legacy workspace-write additionally receives `${config.devenv.root}/.git` for
compatibility. Named permissions instead begin with devenv's automatically
populated `config.git.root`, inspect its `.git` directory or pointer file, and
resolve linked-worktree `gitdir` plus `commondir` metadata to the canonical
shared common Git directory. Absolute and relative metadata values are both
supported, and directory-form Git metadata follows its own `commondir` when
present. The resolver requires the Git directory's `HEAD` and the common
directory's config plus object database before emitting a rule, so an arbitrary
directory named by a forged pointer cannot become a broad write grant. The
result is a direct filesystem write rule, never a workspace root; a non-Git
project emits no Git rule. A parent used to write several worktrees remains
explicit repository-topology policy.

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
`ai.<runtime>.programs.stacked-workflows.enable = false` retracts that runtime's
package contribution without affecting siblings. The removed top-level package
enable option has no alias. `stacked-workflows.gitPreset` is deliberately not
part of the program tree: it configures Home Manager's machine-wide
`programs.git.settings`, has no runtime meaning, and remains an HM-only
companion instead of creating misleading runtime overrides.

**The contributions land PER RUNTIME, not on the root pool** — since 2026-08-14
the factory writes `ai.<runtime>.skills` and `ai.<runtime>.rules` for every
runtime whose module is present in the evaluation, filtered by
`lib.hasAttrByPath ["ai" name "skills"] options`. Root `ai.skills` belongs to
the consumer as a portable default surface. Per-runtime null can now retract an
inherited key, but packages still do not write root values that fan out beyond
their runtime ownership. The `rootPoolViolations` provenance guard in
`checks/module-provenance/helpers.nix` enforces this by reading each root
option's `definitionsWithLocations`. The declaring module is exempt, which lets
`sharedOptions.nix` perform its root L1→L2 Dir reshape.

Two consequences to know before changing it. Consumer override keys are
`ai.<runtime>.skills.<name>` and `ai.<runtime>.rules.<name>`; package entries
use `mkDefault`, so an ordinary per-runtime consumer definition or null wins. A
same-key root entry remains a portable default and is atomically replaced by the
package's per-runtime value. Two packages claiming that per-runtime key fail the
package-provenance guard (see `collision-semantics.md`).
