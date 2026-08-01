## ai Module Fanout Semantics

> **Last verified:** 2026-08-01 (commit pending — Codex now lowers shared and
> per-app context, instructions, and unscoped Markdown rules into global HM and
> project-local devenv AGENTS.md files; scoped content fails explicitly pending
> its degradation policy). Prior: 2026-08-01 (commit 914096a8 — Codex joins the
> factory with an enable/package-only vertical in both backends). Prior:
> 2026-07-27 (commit pending — re-points the claude-code wrapping cite from
> `packages/ai-clis/claude-code.nix`, a path that no longer exists, to
> `overlays/claude-code.nix`; prior 2026-04-08, A10 delete modules/ tree). If
> you change the gating, the `programs.*.enable` flipping, or the
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
| `ai.codex.enable = true`   | Codex package installation + native AGENTS.md fanout                  |
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

**Cross-ecosystem options** (live at `ai.*` top level, fan out to every enabled
ecosystem simultaneously):

- `ai.skills` — attrset of name → directory path. Each enabled ecosystem gets
  its native representation (Claude: `.claude/skills/<name>` symlink; Copilot
  and Kiro: native `skills` option on their module).
- `ai.instructions` — list of instruction records (text plus optional name, path
  scoping, and description). Transformed per ecosystem via
  `fragments-ai.passthru.transforms`: Claude gets `.claude/rules/<name>.md` with
  YAML frontmatter; Copilot gets `.github/instructions/<name>.instructions.md`;
  Kiro gets `.kiro/steering/<name>.md` (via the CLI module); Codex concatenates
  entries into its single AGENTS.md without frontmatter.
- `ai.context` — a single global baseline. Codex lowers it to
  `~/.codex/AGENTS.md` in Home Manager and project-root `AGENTS.md` in devenv;
  `ai.codex.context` takes precedence when set.
- `ai.rules` — named Markdown rules. Codex appends these alphabetically to its
  AGENTS.md with trace comments. Scoped Codex rules currently fail explicitly
  rather than silently losing their scope; the follow-up degradation surface
  will preserve scope as prose.
- `ai.lspServers` — typed LSP definitions, translated to each ecosystem's native
  LSP config format (Claude via `ENABLE_LSP_TOOL=1`; Copilot has `lspServers`
  option; Kiro too).
- `ai.environmentVariables` — shared env vars; Copilot and Kiro fan out
  directly, Claude has no native option so Claude itself receives nothing from
  this (intentional — Claude env goes via `programs.claude-code.settings.env`
  directly).

All cross-ecosystem fanouts use `mkDefault` so per-CLI overrides take
precedence.

### Assertion semantics

Three assertions live in the config block, always evaluated (no mkIf gate to
skip them):

1. `ai.copilot.enable` requires `programs.copilot-cli` module to be imported
2. `ai.kiro.enable` requires `programs.kiro-cli` module to be imported
3. If any cross-ecosystem option is set (skills, instructions,
   environmentVariables), at least one ecosystem must be enabled — otherwise the
   config does nothing and the user didn't notice

### What's NOT in the ai module

- The package wrapping (Bun runtime) for claude-code — handled in
  `overlays/claude-code.nix` at overlay level.
- MCP server config — ai has no `mcpServers` option. Consumers configure
  `programs.mcp.servers` or per-CLI `mcpServers` directly. This is intentional:
  the ai module stayed focused on scope that's cleanly cross-ecosystem. MCP
  integration has enough ecosystem-specific quirks that centralizing it would
  have been more pain than value.

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
`ai.environmentVariables`, `ai.agents`, `ai.context`). It's imported by BOTH
`hmTransform.nix` and `devenvTransform.nix`.

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
