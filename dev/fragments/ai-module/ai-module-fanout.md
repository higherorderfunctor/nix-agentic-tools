## ai Module Fanout Semantics

> **Last verified:** 2026-08-02 (commit pending — the native-surface audit adds
> static Home Manager profile files and records why Codex has no LSP or shared
> wrapper-environment fanout). Prior: 2026-08-02 (commit 3546267a — Codex Home
> Manager settings reconcile exact Nix-owned TOML leaves into a writable user
> file because the native trust prompt persists ad-hoc project decisions through
> `config/batchWrite`; devenv retains whole-file static project ownership until
> a project-local writer is demonstrated). Prior: 2026-08-01 (commit pending —
> portable semantic agents fan out to Claude, Copilot, and Codex while portable
> lifecycle command hooks fan out to Claude and Codex; Codex emits native
> standalone agent TOML and `hooks.json`; conventional packages lower to their
> executable while bare-file derivations remain direct command paths). Prior:
> 2026-08-01 (commit pending — Codex materializes native Starlark execpolicy
> files independently from Markdown instruction rules and reserves the
> user-mutated `default.rules`). Prior: 2026-08-01 (commit pending — Codex types
> beta named permission profiles, including filesystem, network, inheritance,
> and workspace root policy). Prior: 2026-08-01 (commit pending — Codex types
> stable sandbox, approval, and user-global project-trust settings, rejects
> trust declarations at project scope, and prevents legacy sandbox settings from
> composing with beta permission profiles). Prior: 2026-08-01 (commit pending —
> Codex lowers shared and per-app typed MCP servers to native `mcp_servers`
> tables in both backends, including credential wrappers and Codex-specific
> policy extensions). Prior: 2026-08-01 (commit pending —
> `ai.settings.reasoningEffort` lowers through the exact Claude/Codex persisted
> semantic intersection, with native settings overriding or excluding the shared
> default). Prior: 2026-08-01 (commit d7755c2f — Codex statically lowers a
> typed/freeform settings surface to user and trusted-project config.toml).
> Prior: 2026-08-01 (commit 4562252c — Codex lowers shared and per-app skills to
> `.agents/skills` in both backends). Prior: 2026-08-01 (commit 444a6f97 — Codex
> degrades scoped instructions and rules to explicit prose, supports opt-out
> through `skipIfUnsupported`, and rejects generated AGENTS.md content over its
> configurable byte limit). Prior: 2026-08-01 (commit c6b1b31e — Codex lowers
> shared and per-app context, instructions, and unscoped Markdown rules into
> global HM and project-local devenv AGENTS.md files). Prior: 2026-08-01 (commit
> 914096a8 — Codex joins the factory with an enable/package-only vertical in
> both backends). Prior: 2026-07-27 (commit pending — re-points the claude-code
> wrapping cite from `packages/ai-clis/claude-code.nix`, a path that no longer
> exists, to `overlays/claude-code.nix`; prior 2026-04-08, A10 delete modules/
> tree). If you change the gating, the `programs.*.enable` flipping, or the
> cross-ecosystem data flow in the per-package factories
> (`packages/*/lib/mk*.nix`) or shared options (`lib/ai/sharedOptions.nix`) and
> this fragment isn't updated in the same commit, stop and fix it.

The `ai.*` HM module provides a unified interface that fans out shared AI-CLI
configuration to each enabled ecosystem (Claude, Codex, Copilot, Kiro). It is
NOT a thin wrapper — the gating semantics, default-setting behavior, and fanout
patterns are load-bearing and got bitten into production by a silent no-op bug.
Read this fragment before changing the gating.

### There is no `ai.enable`

The `ai` module has **no master enable option**. Each per-CLI sub-enable is the
sole gate for that ecosystem's fanout:

| Consumer sets              | What fires                                                            |
| -------------------------- | --------------------------------------------------------------------- |
| `ai.claude.enable = true`  | claude fanout block + `programs.claude-code.enable = mkDefault true`  |
| `ai.codex.enable = true`   | Codex package + instructions, skills, settings, agents, hooks fanout  |
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

### Fanout data flow

The ai module fans out TWO kinds of configuration:

**Per-CLI options** (live inside `ai.{claude,codex,copilot,kiro}.*`):

- `ai.claude.package` / `ai.codex.package` / `ai.copilot.package` /
  `ai.kiro.package` — package override; Codex installs it directly while the
  established runtimes route it through their native factory wiring.
- `ai.codex.settings` — typed stable keys plus a TOML-compatible native freeform
  tail. Home Manager reconciles exact declared leaves into a writable
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
  network proxy/domain/socket policy. The older sandbox model and permission
  profiles are mutually exclusive, so the module fails when both are present.
  Profile names and inheritance graphs remain runtime-validated by Codex because
  config layers may contribute parents dynamically. `ai.codex.profiles.<name>`
  emits a separate static `${configDir}/<name>.config.toml` user layer selected
  with `codex --profile <name>`. Profiles are intentionally Home Manager-only:
  current Codex no longer accepts an in-file default selector, resolves profile
  files only from user CODEX_HOME, and ignores profile keys in project config.
  Devenv rejects non-empty profile declarations instead of writing an inert
  project artifact. `projects.<path>.trust_level` is accepted only by Home
  Manager's user-global file: devenv rejects it because a project cannot
  bootstrap the trust required to load its own `.codex/config.toml`.
  `ai.codex.execpolicyRules.<name>` writes native Starlark to
  `<config-layer>/rules/<name>.rules` in both backends. It is intentionally
  separate from Markdown `ai.rules`, which remains durable AGENTS.md guidance.
  Home Manager reserves `execpolicyRules.default` because Codex appends accepted
  user allow-list decisions to `$CODEX_HOME/rules/default.rules`; other
  per-entry files remain declarative while that native mutation can coexist.
  Trusted project rules are declarative and may use `default` because Codex's
  native writer targets only the user layer.
- `ai.codex.agents.<name>` — the semantic agent record plus a freeform `codex`
  TOML extension. Home Manager emits `${configDir}/agents/<name>.toml`; devenv
  emits trusted-project `.codex/agents/<name>.toml`. The filename stem supplies
  native `name`, while `description` and `instructions` lower to the two other
  required native fields. Reserved core fields cannot be redefined in `codex`.
  Global concurrency, model/effort defaults, and interruption behavior live in
  the typed `ai.codex.settings.agents` table.
- `ai.codex.hooks.<Event>` — Codex-native matcher groups and command handlers,
  appended after portable `ai.hooks` groups and emitted in adjacent
  `hooks.json`. Typed native additions include `commandWindows`,
  `statusMessage`, and `additionalContextLimit`; a JSON-compatible tail remains
  for forward compatibility. Typed hooks cannot coexist with inline
  `ai.codex.settings.hooks` at one layer because Codex loads both additively and
  warns rather than applying normal config precedence. Nix ownership does not
  make these native-policy hooks: Codex still requires `/hooks` review and
  hash-based trust before user/project handlers run.

**Cross-ecosystem options** (live at `ai.*` top level and fan out to each
enabled ecosystem whose native model preserves the option's semantics):

- `ai.settings.reasoningEffort` — the portable `low` / `medium` / `high` /
  `xhigh` intersection lowered to Claude `effortLevel` and Codex
  `model_reasoning_effort`. Values that only one runtime persists (`max` and
  `ultra` in Codex) remain native-only. A native per-runtime value has normal
  option priority over the aggregate `mkDefault`; explicitly setting the native
  key to `null` excludes that runtime from the fanout.
- `ai.skills` — attrset of name → directory path. Each enabled ecosystem gets
  its native representation. Codex uses user-global `$HOME/.agents/skills` in HM
  and repository-local `.agents/skills` in devenv; Claude, Copilot, and Kiro use
  their established native directories.
- `ai.agents` — either legacy Markdown/path entries for Claude and Copilot or a
  portable `{ description, instructions, codex? }` record. Semantic records
  render Claude/Copilot frontmatter plus body and Codex standalone TOML. Codex
  fails loudly on a legacy raw entry instead of pretending Markdown is a valid
  agent config. Legacy Nix paths stay path-valued for Claude's native option but
  are read into text for Copilot's file writer. Kiro remains excluded because
  its JSON agent model has no lossless mapping to this intersection.
- `ai.hooks` — command-only matcher groups across the exact shared Claude/Codex
  lifecycle event set. Shared groups run before per-runtime groups for the same
  event. Matcher strings pass through, so consumers must stay within the regex
  subset understood by both runtimes. Non-portable events fail with a diagnostic
  and belong under `ai.claude.hooks` or `ai.codex.hooks`. Command packages with
  a `meta.mainProgram` or conventional `pname` resolve to their package
  executable; bare-file derivations remain direct output paths. Kiro's v3
  trigger records remain native-only.
- `ai.instructions` — list of instruction records (text plus optional name, path
  scoping, and description). Transformed per ecosystem via
  `fragments-ai.passthru.transforms`: Claude gets `.claude/rules/<name>.md` with
  YAML frontmatter; Copilot gets `.github/instructions/<name>.instructions.md`;
  Kiro gets `.kiro/steering/<name>.md` (via the CLI module); Codex concatenates
  entries into its single AGENTS.md without frontmatter. Scoped entries become
  explicit prose unless `skipIfUnsupported = true` omits them.
- `ai.context` — a single global baseline. Codex lowers it to
  `~/.codex/AGENTS.md` in Home Manager and project-root `AGENTS.md` in devenv;
  `ai.codex.context` takes precedence when set.
- `ai.rules` — named Markdown rules. Codex appends these alphabetically to its
  AGENTS.md with trace comments. Scoped Codex rules preserve their intent as an
  explicit prose prefix unless `skipIfUnsupported = true` omits them. The
  complete rendered file must fit `ai.codex.projectDocMaxBytes` (32 KiB by
  default), or evaluation fails with per-contribution byte diagnostics. Codex
  also rejects `paths = []` as ambiguous; use `null` for always-on content or a
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
  values never enter generated TOML. Direct `ai.codex.settings.mcp_servers`
  cannot be combined with either typed pool because their table ownership would
  be ambiguous.
- `ai.lspServers` — typed LSP definitions, translated to Claude, Copilot, and
  Kiro native config. Codex is deliberately excluded: its current public config
  reference and pinned CLI expose no LSP-server registration surface, so
  pretending to fan out this pool would silently discard the declaration.
- `ai.environmentVariables` — shared env vars; Copilot and Kiro fan out
  directly, Claude has no native option so Claude itself receives nothing from
  this (intentional — Claude env goes via `programs.claude-code.settings.env`
  directly). Codex is also excluded: its `shell_environment_policy` configures
  the environment inherited by spawned commands, while this pool configures the
  AI CLI process itself. Consumers should use normal Home Manager/devenv
  environment facilities for Codex runtime variables and the native freeform
  setting for child-command filtering.

Cross-ecosystem scalar defaults and per-entry fanouts use `mkDefault` so per-CLI
overrides take precedence. Collection pools use their documented collision or
concatenation semantics instead.

### Assertion semantics

Fanout assertions live outside per-runtime enable gates so invalid shared data
cannot hide behind a disabled CLI. This includes collision checks and the
portable hook-event vocabulary check. Runtime-specific materialization
assertions remain inside the enabled runtime's factory—for example, Codex's
semantic-agent requirement and its `hooks.json` versus inline-hook ownership
check.

### Other boundaries

- The package wrapping (Bun runtime) for claude-code — handled in
  `overlays/claude-code.nix` at overlay level.

See the backlog item "ai.claude.\* full passthrough" for the ongoing work to
expose more `programs.claude-code.*` options via `ai.claude.*`.

### Config parity

Every option on the HM ai module must have a matching option on the devenv ai
module with the same semantics. If you add an option to one, add it to the other
in the same commit. This is enforced by convention, not by the module system.

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

`lib/ai/sharedOptions.nix` declares cross-app pools (`ai.skills`,
`ai.instructions`, `ai.rules`, `ai.mcpServers`, `ai.lspServers`,
`ai.environmentVariables`, `ai.agents`, `ai.hooks`, `ai.context`). It's imported
by BOTH `hmTransform.nix` and `devenvTransform.nix`.

**The option declarations are shared. The values are NOT.**

HM and devenv run separate `evalModules` invocations with independent config
trees. A value set in the HM-imported copy of a module is visible only to HM's
eval. Devenv's eval has a completely separate `config.ai.skills` (etc.) that
doesn't see the HM contribution.

**Consequence for "plain modules"** (not `mkAiApp` participants, like
`packages/stacked-workflows/modules/`): when a plain module contributes to
`ai.skills` / `ai.instructions` / etc., the contribution MUST happen in the
module's appropriate backend sibling. If the content is HM-scope (personal user
config), put it in the HM module. If it's project-scope (devenv-only), put it in
the devenv module. Contributing in one and expecting the other to pick it up
will silently fail — the contribution just doesn't land in the other eval.

This is a different discipline from the AI CLI factories (`mkAiApp`), which have
structural `hm = { config = …; }` / `devenv = { config = …; }` blocks that force
per-backend separation by construction. Plain modules have no such guardrail —
authors must decide scope consciously.

**Worked example — stacked-workflows skills.** Because an `ai.skills` value set
in one backend is invisible to the other, the stacked-workflows package
contributes its `stack-*` skills from BOTH backend modules: the HM module
installs them user-global (`~/.claude/skills/stack-*`, ...) and the devenv
module installs them project-local — two separate, deliberate contributions, one
per eval. A 2026-04 bug drove the lesson home: the skills were contributed from
ONLY the HM module while a shared devenv pool was expected to "pick them up", so
devenv consumers saw nothing while the HM contribution alone reached personal
scope. It was first scoped to the devenv module (commit `940ec54c`); the current
design re-adds the HM contribution as its own explicit, user-global emission, so
both backends now contribute (each via `lib/ai/mkSkillPackageModule`).
