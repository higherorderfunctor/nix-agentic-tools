## ai Module Fanout Semantics

> **Last verified:** 2026-08-15 (commit pending — the `ai.programs.*` factory
> generates portable defaults and capability-gated runtime override trees from
> one program specification; Semble is its first consumer and uses program-level
> enable negation instead of runtime selectors; divergent runtime package
> customizations use collision-free command aliases and isolated caches). Prior:
> 2026-08-15 (commit pending — top-level proxied MCP declarations now own one
> shared managed daemon and fan out only lowered client entries; runtime
> declarations own directly, duplicate ownership keys fail explicitly, and
> unused top-level owners are never materialized). Prior: 2026-08-15 (commit
> pending — normalized keyed pools use atomic per-runtime replacement and null
> tombstones, with same-scope package ownership checked from definition
> provenance). Prior: 2026-08-15 (commit pending — context is a typed
> `text`-XOR-`source` record that composes root-first with runtime context and
> names its native artifact per runtime. Rules carry a normalized `matcher`;
> Claude, Kiro, Copilot, and Codex lower it to native metadata or explicit
> prose, and devenv AGENTS.md consumers share one keyed deduplicating writer;
> the list-shaped `instructions` surface is retired rather than aliased). Prior:
> 2026-08-15 (commit pending — every normalized pool crosses into a runtime only
> when its app record lists it in `supportedPools`; all five runtimes now list
> the closed normalized `settings` submodule, runtime-native passthrough moved
> to `nativeSettings`, per-runtime fields resolve against the root
> independently, and Codex integration roots travel through a hidden internal
> channel before native TOML emission). Prior: 2026-08-14 (commit pending —
> Copilot's `ai.instructions` / `ai.rules` destination is per-BACKEND and this
> entry named only one of them. Home Manager wrote a hardcoded
> `.github/instructions/`, which resolves to `$HOME/.github/instructions/` — a
> directory copilot-cli never reads — so every named instruction and every rule
> was emitted and then ignored. It now routes through `ai.copilot.configDir`,
> matching every other HM artifact this module writes. See
> `copilot-config-delivery.md` for why the two backends address genuinely
> different consumers). Prior: 2026-08-14 (commit pending — adds the
> Kiro-specific `extraPackages` runtime PATH prefix, shared by both backends
> through the existing launcher wrapper and deliberately not promoted to
> `ai.shell` or a cross-runtime pool). Prior: 2026-08-05 (commit pending —
> Codex's beta permission model is LOCKED OUT: `ai.codex.profiles`,
> `ai.codex.nativeSettings.default_permissions`, and
> `ai.codex.nativeSettings.permissions` stay typed and still emit, but every
> entry point now asserts. A layer carrying the beta model OVERRIDES rather than
> merges the legacy sandbox settings beneath it, and a Nix evaluation cannot see
> across config layers to catch that — measured with `codex sandbox` 0.146.1,
> where this repo's own former profile silently dropped the module-contributed
> `~/.cache/nix` root). Prior: 2026-08-05 (commit pending — Codex's devenv
> Nix-cache resolver remains environment-backed in production but accepts a
> test-only `specialArgs` override through the module's ellipsis instead of
> declaring an unsatisfied formal module argument; ordinary module evaluation
> now has an explicit regression test alongside deterministic XDG/HOME cases).
> Prior: 2026-08-05 (commit pending — Codex's backend-native writable roots are
> now gated by `ai.codex.enable`, so merely configuring dormant Codex settings
> cannot create an active sandbox root set). Prior: 2026-08-05 (commit pending —
> sandbox-safe Git SSH now forces batch mode so agent-backed authentication
> works but missing credentials fail without an interactive dialog). Prior:
> 2026-08-05 (commit pending — every enabled AI harness now receives a
> sandbox-safe Git SSH default in both backends; Codex contributes its
> backend-native Nix cache and devenv Git metadata roots, while enabled
> integrations such as glab add their effective writable state). Prior:
> 2026-08-04 (commit pending — `ai.kiro.agents` is now a typed record modelling
> Kiro's v3 agent schema, with `name` defaulted from the attr key because Kiro's
> Rust CLI requires that field while its Node/ACP parser treats it as optional;
> the `ai.agents` Kiro exclusion is re-justified on tool VOCABULARY rather than
> on JSON-vs-record shape). Prior: 2026-08-02 (commit pending — Codex beta
> permission profiles remain explicit security boundaries: they do not compose
> with legacy `sandbox_workspace_write` integration roots, so a selected profile
> must grant the Semble cache itself). Prior: 2026-08-02 (commit pending —
> portable agent tool lists render native allowlist frontmatter only when
> non-empty, so both `null` and `[]` preserve unrestricted Claude/Copilot
> behavior). Prior: 2026-08-02 (commit pending — Semble automatically grants its
> cache when a selected Codex integration uses the workspace-write sandbox, with
> user-global XDG cache ownership in HM and project-local state plus an
> environment override in devenv). Prior: 2026-08-02 (commit pending — portable
> semantic agents may restrict Claude and Copilot with their shared `tools`
> vocabulary while Codex deliberately omits that field and Kiro retains its
> native JSON model). Prior: 2026-08-02 (commit pending — Semble keeps Claude
> and Codex instructions unnamed for their single-file composers but names its
> Kiro instruction so directory-native steering emits `semble.md` instead of the
> generic `instructions.md`). Prior: 2026-08-02 (commit pending — records plain
> convenience modules such as Semble contributing selected per-runtime defaults
> without enabling those runtimes). Prior: 2026-08-02 (commit pending — Codex
> named profile files now use one typed settings schema across HM and devenv: HM
> links user-global files, while devenv safely materializes repository-declared
> whole-file layers into CODEX_HOME before shell entry). Prior: 2026-08-02
> (commit pending — instruction and rule records carry a typed Kiro-only
> inclusion override with identical HM/devenv fanout; null preserves
> paths-derived `always`/`fileMatch`, while explicit `auto` and `manual` make
> all four native modes reachable). Prior 2026-08-02: the generated reference
> gate now proves exact option-name/type parity for the complete `ai.*` surface;
> the audit closed its sole gap by sharing `ai.copilot.projectDir` while
> explicitly rejecting project-only customization in Home Manager, and the
> instruction fanout points at the current `lib/ai/transformers/` implementation
> rather than the removed fragments package. Prior: 2026-08-02 (commit 589fa37c
> — consumer documentation exposes Codex and its intentional fanout exclusions,
> while generated HM and devenv option references are built and checked for
> exact Codex option-tree parity plus truthful shared-pool descriptions). Prior:
> 2026-08-02 (commit d510586b — the reverse extracted-surface audit derives
> Codex's closed sandbox/approval enums from the pinned sidecar and adds an
> exact human-reviewed disposition gate for every extracted command, flag,
> field, feature maturity, model field, and config seam). Prior: 2026-08-02
> (commit 2eb54cef — the native-surface audit adds static Home Manager profile
> files and records why Codex has no LSP or shared wrapper-environment fanout).
> Prior: 2026-08-02 (commit 3546267a — Codex Home Manager settings reconcile
> exact Nix-owned TOML leaves into a writable user file because the native trust
> prompt persists ad-hoc project decisions through `config/batchWrite`; devenv
> retains whole-file static project ownership until a project-local writer is
> demonstrated). Prior: 2026-08-01 (commit pending — portable semantic agents
> fan out to Claude, Copilot, and Codex while portable lifecycle command hooks
> fan out to Claude and Codex; Codex emits native standalone agent TOML and
> `hooks.json`; conventional packages lower to their executable while bare-file
> derivations remain direct command paths). Prior: 2026-08-01 (commit pending —
> Codex materializes native Starlark execpolicy files independently from
> Markdown instruction rules and reserves the user-mutated `default.rules`).
> Prior: 2026-08-01 (commit pending — Codex types beta named permission
> profiles, including filesystem, network, inheritance, and workspace root
> policy). Prior: 2026-08-01 (commit pending — Codex types stable sandbox,
> approval, and user-global project-trust settings, rejects trust declarations
> at project scope, and prevents legacy sandbox settings from composing with
> beta permission profiles). Prior: 2026-08-01 (commit pending — Codex lowers
> shared and per-app typed MCP servers to native `mcp_servers` tables in both
> backends, including credential wrappers and Codex-specific policy extensions).
> Prior: 2026-08-01 (commit pending — `ai.settings.reasoningEffort` lowers
> through the exact Claude/Codex persisted semantic intersection, with native
> settings overriding or excluding the shared default). Prior: 2026-08-01
> (commit d7755c2f — Codex statically lowers a typed/freeform settings surface
> to user and trusted-project config.toml). Prior: 2026-08-01 (commit 4562252c —
> Codex lowers shared and per-app skills to `.agents/skills` in both backends).
> Prior: 2026-08-01 (commit 444a6f97 — Codex degrades scoped instructions and
> rules to explicit prose, supports opt-out through `skipIfUnsupported`, and
> rejects generated AGENTS.md content over its configurable byte limit). Prior:
> 2026-08-01 (commit c6b1b31e — Codex lowers shared and per-app context,
> instructions, and unscoped Markdown rules into global HM and project-local
> devenv AGENTS.md files). Prior: 2026-08-01 (commit 914096a8 — Codex joins the
> factory with an enable/package-only vertical in both backends). Prior:
> 2026-07-27 (commit pending — re-points the claude-code wrapping cite from
> `packages/ai-clis/claude-code.nix`, a path that no longer exists, to
> `overlays/claude-code.nix`; prior 2026-04-08, A10 delete modules/ tree). If
> you change the gating, the `programs.*.enable` flipping, or the
> cross-ecosystem data flow in the per-package factories
> (`packages/*/lib/mk*.nix`) or shared options (`lib/ai/sharedOptions.nix`) and
> this fragment isn't updated in the same commit, stop and fix it.

The `ai.*` HM module provides a unified interface that fans out shared AI-CLI
configuration to each capable enabled ecosystem (Claude, Codex, Copilot, Kimchi,
Kiro). It is NOT a thin wrapper — the gating semantics, default-setting
behavior, and fanout patterns are load-bearing and got bitten into production by
a silent no-op bug. Read this fragment before changing the gating.

### Codex extracted facts need reverse coverage

`overlays/chatgpt-codex-extracted.json` is generated fact from the pinned
binary. `packages/chatgpt-codex/lib/extractedCoverage.nix` is the separate,
human-reviewed ownership decision. Never generate the second from the first:
`checks/chatgpt-codex-coverage.nix` intentionally fails when a bump introduces a
command, canonical flag, record field, feature maturity, or config-key seam
without an explicit Nix disposition.

Dynamic policy is still coverage. Stable feature names become typed directly
from the sidecar, non-stable names remain available through the boolean freeform
table, model slugs stay strings because availability is account- and
provider-dependent, and extracted reasoning levels feed typed enums. The closed
`--sandbox` and `--ask-for-approval` value sets also feed their typed options
directly; do not restore parallel handwritten lists.

### There is no `ai.enable`

The `ai` module has **no master enable option**. Each per-CLI sub-enable is the
sole gate for that ecosystem's fanout:

| Consumer sets              | What fires                                                            |
| -------------------------- | --------------------------------------------------------------------- |
| `ai.claude.enable = true`  | claude fanout block + `programs.claude-code.enable = mkDefault true`  |
| `ai.codex.enable = true`   | Codex package + guidance, skills, settings, agents, hooks fanout      |
| `ai.copilot.enable = true` | copilot fanout block + `programs.copilot-cli.enable = mkDefault true` |
| `ai.kiro.enable = true`    | kiro fanout block + `programs.kiro-cli.enable = mkDefault true`       |

Where an upstream module exists, each per-CLI block implicitly flips its enable
via `mkDefault`, so consumers don't have to set enable twice. Codex has no
upstream module: its factory installs `ai.codex.package` directly in each
backend. For CLIs that do have an upstream module, a consumer can still override
the corresponding `programs.<cli>.enable` explicitly.

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

**Per-CLI options** (live inside `ai.{claude,codex,copilot,kiro}.*`):

- `ai.claude.package` / `ai.codex.package` / `ai.copilot.package` /
  `ai.kiro.package` — package override; Codex installs it directly while the
  established runtimes route it through their native factory wiring.
- `ai.kiro.extraPackages` — store-backed tools added to Kiro's runtime PATH in
  both backends. It is Kiro-specific because it closes the Linux `buildFHSEnv`
  visibility gap; it remains independent of `ai.shell`, which selects an
  executable rather than supplying commands.
- `ai.codex.nativeSettings` — typed stable keys plus a TOML-compatible native
  freeform tail. Home Manager reconciles exact declared leaves into a writable
  `${configDir}/config.toml`; devenv writes a statically Nix-owned
  trusted-project `.codex/config.toml`. An empty first HM generation is a no-op,
  while an empty later generation uses the ownership manifest to remove formerly
  managed leaves without deleting native state. Devenv rejects provider,
  profile, notification, and telemetry keys that Codex documents as ignored at
  project scope. The backend ownership difference is deliberate: Codex's
  user-level trust prompt writes ad-hoc `projects.<path>.trust_level` entries
  into the same file through `config/batchWrite`, while no project-local writer
  has been observed. A versioned XDG-state manifest tracks Nix-owned leaf paths
  so activation can reassert and retire them while preserving unknown/native
  siblings, including siblings inside `projects`, `features`, and `mcp_servers`.
  MCP configuration is composed into that shared user file or the static project
  file through the same typed server pool. Stable security settings type
  `allow_login_shell`, `approval_policy` (including granular prompt categories),
  `approvals_reviewer`, `sandbox_mode`, and `sandbox_workspace_write`. Beta
  `default_permissions` and named `permissions` profiles type inheritance,
  workspace roots, filesystem access and scoped paths, deny-glob scan depth, and
  network proxy/domain/socket policy. **All three of `default_permissions`,
  `permissions`, and `profiles` are LOCKED OUT: they are typed and emit
  correctly, but setting any of them fails evaluation.** The two sandbox models
  are mutually exclusive and Codex resolves a layer carrying the beta model by
  OVERRIDING rather than merging the legacy settings beneath it, silently
  dropping every writable root the lower layer granted. The intra-layer
  assertion below is the only scope a Nix evaluation can see; the cross-layer
  case is structurally invisible to it, which is why the surface is closed
  rather than merely asserted. See the lockout comment in
  `packages/chatgpt-codex/lib/mkCodex.nix` for the measurement that drove it and
  what re-enabling would require. The mechanics below are retained because they
  are what re-enabling would restore. The older sandbox model and permission
  profiles are mutually exclusive, so the module fails when both are present.
  Profile names and inheritance graphs remain runtime-validated by Codex because
  config layers may contribute parents dynamically. `ai.codex.profiles.<name>`
  uses the same typed/freeform settings schema and emits a separate static
  `${configDir}/<name>.config.toml` user layer selected with
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
  and repository-local `.agents/skills` in devenv; Claude, Copilot, and Kiro use
  their established native directories.
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
  repository consumed by github.com, not copilot-cli's user home.
- `ai.rules` — named Markdown rules. Codex appends these alphabetically to its
  AGENTS.md after context with trace comments. `matcher = null` means always-on;
  non-empty glob lists lower to Claude `paths`, Kiro `fileMatchPattern`, Copilot
  `applyTo`, and a Codex prose scope preamble. Kiro alone retains native
  `manual`/`auto` inclusion overrides. The complete rendered file must fit
  `ai.codex.projectDocMaxBytes` (32 KiB by default), or evaluation fails with
  per-contribution byte diagnostics. Codex also rejects `matcher = []` as
  ambiguous; use `null` for always-on content or a non-empty list for scoped
  content.
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
  `overlays/claude-code.nix` at overlay level.

See the backlog item "ai.claude.\* full passthrough" for the ongoing work to
expose more `programs.claude-code.*` options via `ai.claude.*`.

### Config parity

Every option on the HM ai module must have a matching option on the devenv ai
module with the same semantics. If you add an option to one, add it to the other
in the same commit. Codex's exact generated option-name set is compared across
both backends by `checks/options-doc.nix`. Runtime scope differences belong in
backend lowering, not divergent declarations: `ai.codex.profiles` is one typed
surface, with HM linking its user-global files and devenv materializing the same
whole-file layers from repository declarations into the native user lookup
location.

### Documentation parity is capability parity

Do not describe every top-level pool as mechanically reaching all four runtimes.
The shared option descriptions and generated README capability matrix must name
Codex either as a consumer or as an intentional exclusion. In particular, Codex
has no native LSP registry; its `shell_environment_policy` filters child-command
inheritance rather than setting the Codex process environment; legacy Markdown
agents cannot become native Codex TOML; and only the Claude/Codex lifecycle
intersection belongs in portable hooks.

`lib/options-doc.nix` evaluates both complete published module trees and
produces their CommonMark/JSON references. The old mdbook/NuschtOS site is gone,
but `checks/options-doc.nix` deliberately builds both renderings so this
consumer-facing contract cannot become dead code. It compares every `ai.codex.*`
option name, checks the expected top-level surface, and verifies that
shared-pool descriptions discuss Codex. README.md remains generated from
`dev/generate.nix`; `checks/instructions-drift.nix` prevents its checked-in
capability matrix from diverging from that source.

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

**Consequence for "plain modules"** (not `mkAiApp` participants, like
`packages/stacked-workflows/modules/`): when a plain module contributes to
`ai.skills` / `ai.rules` / etc., the contribution MUST happen in the module's
appropriate backend sibling. If the content is HM-scope (personal user config),
put it in the HM module. If it's project-scope (devenv-only), put it in the
devenv module. Contributing in one and expecting the other to pick it up will
silently fail — the contribution just doesn't land in the other eval.

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
replacement. For Semble feature selection, an explicit runtime feature value is
more specific still; otherwise the runtime program value takes precedence over
an inherited portable feature value. The program still must not set
`ai.<runtime>.enable`, because package/CLI activation remains an explicit
consumer choice.

Semble is the first factory consumer. Its single spec supports Claude, Codex,
and Kiro, and generates its named MCP, agent, and `semble` rule defaults in both
backend evaluations. The rule composes into Claude and Codex's single
always-loaded files and lets Kiro's directory-native renderer write `semble.md`.

Semble also treats Codex's selected sandbox mode as an integration boundary. A
selected Codex feature plus `sandbox_mode = "workspace-write"` appends that
runtime's effective Semble cache to `sandbox_workspace_write.writable_roots`.
Home Manager's cache family starts at `${config.xdg.cacheHome}/semble`; devenv's
starts at `${config.devenv.state}/semble-cache`. One resolved package uses that
root. Distinct runtime packages use package-keyed `variants/` subdirectories,
receive runtime-specific CLI aliases, and never share an incompatible
customization fingerprint. Launcher wrappers fix `SEMBLE_CACHE_LOCATION` for
their own variant; there is no consumer environment override. The convenience
module does not select a sandbox mode, and read-only or unrestricted modes get
no writable-root contribution. Codex's beta `default_permissions`/`permissions`
model does not compose with those legacy sandbox settings. A named permission
profile is an explicit security boundary and must grant the cache path in its
own `filesystem` table; user-global integrations must not silently widen every
higher-precedence profile.

Codex itself contributes the roots needed by its normal backend lifecycle when
the consumer selects legacy `sandbox_mode = "workspace-write"`: Home Manager
adds `${config.xdg.cacheHome}/nix`; devenv adds `${config.devenv.root}/.git`
plus the effective process user's Nix cache. The devenv cache follows
`XDG_CACHE_HOME` when present and otherwise `$HOME/.cache`. The Git root is
deliberately repository-local; a parent directory used for several worktrees
remains an explicit consumer policy choice.

Enabled integrations can append their own runtime-owned state through the hidden
`ai.codex.internal._integration_writable_roots` pool. It is module plumbing
rather than a user setting, is omitted from generated option docs, and is folded
into native `sandbox_workspace_write.writable_roots` only when Codex emits its
config. The glab facets add the effective `glab.configDir`, so a devenv consumer
may point project-local glab at an existing Home Manager `~/.config/glab-cli`
and reuse its authentication without another login. The default devenv glab
directory remains project-local state. These automatic roots apply only to the
legacy workspace-write settings. Named permission profiles remain explicit
security boundaries and must declare equivalent paths themselves.

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

**Both contributions land PER RUNTIME, not on the root pool** — since 2026-08-14
the factory writes `ai.<runtime>.skills` and `ai.<runtime>.rules` for every
runtime whose module is present in the evaluation, filtered by
`lib.hasAttrByPath ["ai" name "skills"] options`. Root `ai.skills` belongs to
the consumer as a portable default surface. Per-runtime null can now retract an
inherited key, but packages still do not write root values that fan out beyond
their runtime ownership. The `rootPoolViolations` provenance guard in
`checks/module-eval.nix` enforces this by reading each root option's
`definitionsWithLocations`. The declaring module is exempt, which lets
`sharedOptions.nix` perform its root L1→L2 Dir reshape.

Two consequences to know before changing it. Consumer override keys are
`ai.<runtime>.skills.<name>` and `ai.<runtime>.rules.<name>`; package entries
use `mkDefault`, so an ordinary per-runtime consumer definition or null wins. A
same-key root entry remains a portable default and is atomically replaced by the
package's per-runtime value. Two packages claiming that per-runtime key fail the
package-provenance guard (see `collision-semantics.md`).
