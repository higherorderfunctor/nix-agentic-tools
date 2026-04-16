## ai Module Fanout Semantics

> **Last verified:** 2026-04-08 (commit pending — A10 delete
> modules/ tree). If you change the gating, the
> `programs.*.enable` flipping, or the cross-ecosystem data flow
> in the per-package factories (`packages/*/lib/mk*.nix`) or
> shared options (`lib/ai/sharedOptions.nix`) and this fragment
> isn't updated in the same commit, stop and fix it.

The `ai.*` HM module provides a unified interface that fans out
shared AI-CLI configuration to each enabled ecosystem (Claude,
Copilot, Kiro, future Codex). It is NOT a thin wrapper — the
gating semantics, default-setting behavior, and fanout patterns
are load-bearing and got bitten into production by a silent
no-op bug. Read this fragment before changing the gating.

### There is no `ai.enable`

The `ai` module has **no master enable option**. Each per-CLI
sub-enable is the sole gate for that ecosystem's fanout:

| Consumer sets              | What fires                                                            |
| -------------------------- | --------------------------------------------------------------------- |
| `ai.claude.enable = true`  | claude fanout block + `programs.claude-code.enable = mkDefault true`  |
| `ai.copilot.enable = true` | copilot fanout block + `programs.copilot-cli.enable = mkDefault true` |
| `ai.kiro.enable = true`    | kiro fanout block + `programs.kiro-cli.enable = mkDefault true`       |

Each per-CLI block implicitly flips the corresponding upstream
module's enable via `mkDefault`, so consumers don't have to set
enable twice. A consumer can still override by setting
`programs.<cli>.enable = false` explicitly, but the default is on
when the ai-level enable is on.

### Why there's no master switch

The original design had `config = mkIf cfg.enable (mkMerge [...])`
wrapping everything, requiring BOTH `ai.enable = true` AND
`ai.claude.enable = true` to fan out. This caused a silent no-op:
a consumer who set `ai.claude.enable = true` without `ai.enable = true`
got no fanout at all — `programs.claude-code` options stayed at
defaults, configuration was stored in the option but never fanned out.

Surfaced 2026-04-07 during HITL integration. Root cause: the outer
`mkIf cfg.enable` gate was false.

Four fix options were considered; option (b) was chosen:

1. Move per-CLI fanout outside the mkIf (kept rest of gating)
2. **Drop `ai.enable` as a master switch entirely** ← chosen
3. Magic-default `ai.enable` from sub-options (opaque)
4. Document the requirement loudly with an assertion

Option (b) is the cleanest: redundant gates create silent failure
modes. Each option that looks like it should "do something" must
actually do something. The master switch added no information
over the per-CLI enables.

Fix landed in commit f2e911c.

### Fanout data flow

The ai module fans out TWO kinds of configuration:

**Per-CLI options** (live inside `ai.{claude,copilot,kiro}.*`):

- `ai.claude.package` / `ai.copilot.package` / `ai.kiro.package`
  — package override, fans out to `programs.<cli>.package`
  **Cross-ecosystem options** (live at `ai.*` top level, fan out
  to every enabled ecosystem simultaneously):

- `ai.skills` — attrset of name → directory path. Each enabled
  ecosystem gets its native representation (Claude:
  `.claude/skills/<name>` symlink; Copilot and Kiro: native
  `skills` option on their module).
- `ai.instructions` — attrset of name → `instructionModule`
  (text + optional path scoping + description). Transformed per
  ecosystem via `fragments-ai.passthru.transforms`: Claude gets
  `.claude/rules/<name>.md` with YAML frontmatter; Copilot gets
  `.github/instructions/<name>.instructions.md`; Kiro gets
  `.kiro/steering/<name>.md` (via the CLI module).
- `ai.lspServers` — typed LSP definitions, translated to each
  ecosystem's native LSP config format (Claude via
  `ENABLE_LSP_TOOL=1`; Copilot has `lspServers` option; Kiro too).
- `ai.settings.{model,telemetry}` — normalized settings; each
  ecosystem has a different native option path (Claude has no
  model setting; Copilot has `settings.model`; Kiro has
  `settings.chat.defaultModel`).
- `ai.environmentVariables` — shared env vars; Copilot and Kiro
  fan out directly, Claude has no native option so Claude itself
  receives nothing from this (intentional — Claude env goes via
  `programs.claude-code.settings.env` directly).

All cross-ecosystem fanouts use `mkDefault` so per-CLI overrides
take precedence.

### Assertion semantics

Three assertions live in the config block, always evaluated (no
mkIf gate to skip them):

1. `ai.copilot.enable` requires `programs.copilot-cli` module to
   be imported
2. `ai.kiro.enable` requires `programs.kiro-cli` module to be
   imported
3. If any cross-ecosystem option is set (skills, instructions,
   environmentVariables), at least one ecosystem must be enabled
   — otherwise the config does nothing and the user didn't notice

### What's NOT in the ai module

- The package wrapping (Bun runtime) for claude-code — handled
  in `packages/ai-clis/claude-code.nix` at overlay level.
- MCP server config — ai has no `mcpServers` option. Consumers
  configure `programs.mcp.servers` or per-CLI `mcpServers`
  directly. This is intentional: the ai module stayed focused
  on scope that's cleanly cross-ecosystem. MCP integration has
  enough ecosystem-specific quirks that centralizing it would
  have been more pain than value.

See the backlog item "ai.claude.\* full passthrough" for the
ongoing work to expose more `programs.claude-code.*` options via
`ai.claude.*`.

### Config parity

Every option on the HM ai module must have a matching option on
the devenv ai module with the same semantics. If you add
an option to one, add it to the other in the same commit.
This is enforced by convention, not by the module system.

### Verifying fanout works

From a consumer repo with the module imported:

```bash
nix eval --impure --json \
  '.#homeConfigurations."<host>".config.programs.claude-code.enable'
# Should be true if ai.claude.enable = true
```

If the option stays false despite `ai.claude.enable = true`, the
fanout is broken — fix the module, not the consumer.
