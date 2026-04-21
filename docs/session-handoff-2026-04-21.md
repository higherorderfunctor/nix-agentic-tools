# Session handoff — 2026-04-21

> **For resumption:** this doc is the hook. Read `docs/plan.md` top,
> then the specific plan journals linked below for deep context.
> Branch is `refactor/ai-factory-architecture`.

## What shipped this session

**24 commits across two autonomous stretches** (after user grants
"keep going / use best judgment / breaking is fine"). Highlights by
area:

### Unified instruction surface

- `ai.context` + `ai.<cli>.context` — single-file global context
  across Claude/Kiro/Copilot, HM + devenv parity (`8f0c16b`,
  `419010a`)
- `ai.rules` + `ai.<cli>.rules` — attrs-shape rules per-CLI
  (`7dad0b8`)
- Design journal: `docs/unified-instructions-design.md`
- **Known miss:** rules/context bake content into the nix store.
  Live-edit semantics (`mkOutOfStoreSymlink`) aren't preserved.
  See "Unfinished: live-edit rules" below.

### Cross-ecosystem pools + typed schemas

- `ai.lspServers` top-level fanout + `ai.claude.lspServers`
  (`bba4f3e`, `46638e6`)
- Typed LSP migration across all three ecosystems
  (`mkLspConfig` / `mkCopilotLspConfig` / `mkClaudeLspConfig`)
  (`e8b23ba`) — design in `docs/ai-lspservers-typed-plan.md`
- `ai.environmentVariables` top-level (Kiro + Copilot; Claude env
  via settings) (`f9d6730`)
- `ai.agents` top-level (Claude + Copilot; Kiro excluded — JSON
  shape differs) (`048470b`) — design in `docs/ai-agents-plan.md`

### Claude-only gap closures

- `ai.claude.marketplaces` + `ai.claude.outputStyles` — identity
  routes to upstream (`b0c1a1a`) — design in
  `docs/ai-claude-extras-plan.md`
- `ai.claude.commands` — Claude-only identity route (`41ef8eb`)
- `ai.claude.hooks` — Claude-only + devenv merge with legacy
  settings.hooks (`27f401f`)
- `ai.claude.settings` devenv translation — hook routing + gap
  write at `files.".claude/settings.json".json` (`796677d`) —
  design in `docs/ai-claude-settings-plan.md`

### Copilot path corrections

- HM `configDir` default: `.config/github-copilot` → `.copilot`
  (breaking, per-backend defaults pattern) (`164b541`) — design in
  `docs/ai-copilot-configdir-plan.md`
- Devenv project-scope restructure: context/agents/skills now at
  `.github/*`; wrapper-dir files stay at `configDir`. New
  `projectDir` option (`446f8a6`) — design in
  `docs/ai-copilot-devenv-restructure-plan.md`

### Cleanup + bug fixes

- Stub collapse — `programs.claude-code` upstream stubs unified to
  `attrsOf anything` in both module-eval + options-doc (`732ca51`)
- **Root-cause fix: stacked-workflows scope bug** — skills /
  instructions / references moved from HM to devenv module. Fixes
  `~/.claude/skills/sws-*` leak into personal scope. Includes
  architectural note in `dev/fragments/ai-module/ai-module-fanout.md`
  on shared-pool per-eval semantics (`940ec54`) — root-cause
  analysis in `docs/stacked-workflows-scope-fix-plan.md`
- Multiple plan.md backlog bullets closed as SHIPPED or OBSOLETE
  with commit references

## Consumer review (nixos-config)

### Current state

- Pin: `f38d03f` (23 commits behind HEAD on
  `refactor/ai-factory-architecture`)
- Location: `/home/caubut/Documents/projects/nixos-config/home/caubut/features/cli/code/ai/default.nix`

### MVP for pin bump

**Nothing in `ai/default.nix` needs to change.** Every option the
consumer uses today still validates against the new pin:

- `ai.mcpServers.*` typed entries unchanged
- `ai.claude.{context, plugins, mcpServers, settings, skills}` all
  still valid
- `ai.kiro.{enable, tui, trustedMcpTools, mcpServers, settings}`
  all still valid
- `ai.copilot.enable` still valid (empty config)
- `ai.skills.gh-repo-settings` top-level pool unchanged
- `stacked-workflows.{enable, gitPreset}` still valid

### Expected visible changes on next `home-manager switch`

From the stacked-workflows scope fix (`940ec54`) — these are
CORRECT now, matching user's original intent:

- `~/.claude/skills/sws-stack-*` disappear
- sws routing table content in `~/.claude/CLAUDE.md` disappears
- `~/.claude/references/*` (philosophy.md, git-absorb.md, etc.) disappear

User's own `stack-*` skills (not sws-prefixed) are untouched.

### ~~Unfinished: live-edit rules~~ SHIPPED `fab4e5c`

Added `ai.<cli>.rules.<name>.sourcePath` (nullable str) —
mutually exclusive with `text`. When set, HM emits
`home.file.<path>.source = config.lib.file.mkOutOfStoreSymlink
rule.sourcePath` and skips transformer frontmatter. Devenv emits
`files.<path>.source = rule.sourcePath` verbatim.

Trade-off: users who want live-edit manage `inclusion:` / `applyTo:`
/ `paths:` frontmatter in their source files directly. Acceptable
for the driving use case (most always-on steering files don't
need frontmatter).

Consumer migration preview (next session, for `nixos-config`):

```nix
# Replace the kiroSymlinkSteering helper + kiroSteeringFiles list with:
ai.kiro.rules =
  lib.mapAttrs
  (name: _: { sourcePath = "${kiroConfigPath}/steering/${name}"; })
  (lib.filterAttrs
    (n: _: lib.hasSuffix ".md" n)
    (builtins.readDir (kiroConfigPath + "/steering")));
```

~20 lines in consumer swapped for auto-discovery of the steering
dir. Factory handles the rest. Live-edit preserved.

Design journal (with pivot notes): `docs/ai-rules-livelink-plan.md`.

## Backlog status

See `docs/plan.md` for the full tree. Summary of top bullets:

- ✅ Unified `ai.context` + `ai.rules` instruction surface
  (Codex size guard deferred with Codex)
- ✅ Unified `ai.mcpServers` + `ai.<cli>.mcpServers`
- ✅ `ai.lspServers` + `ai.environmentVariables` shared options
- ✅ Expose remaining upstream HM claude-code options on `ai.claude`
- ✅ `ai.kiro.trustedMcpTools`
- ✅ `ai.copilot` devenv project-scope restructure
- ⏸ **Typed `ai.claude.settings` / `ai.claude.plugins` schemas** —
  LOW priority; today's identity translation works. When the schema
  diverges from upstream's, needs refactor to hook-routing + gap
  write like devenv does.
- ⏸ **MCP startup failures for github-mcp / kagi-mcp** — active
  investigation from earlier in session. Not unblocked.
- ⏸ **Codex ecosystem** (`mkCodex` factory, 32 KiB size guard,
  `.codex/AGENTS.md` emission). Deferred with the ecosystem.
- ⏸ **mcp-proxy OAuth 2.1 / PRM for kiro-cli 2.0** — blocked on
  upstream; consumer uses direct-stdio workaround.

## Next session suggested priorities

1. **Bump consumer pin** in `nixos-config` — trivial; no
   `ai/default.nix` edits required for MVP.
2. **Migrate 15 kiro steering files to `ai.kiro.rules`** using the
   `sourcePath` pattern shipped in `fab4e5c`. Replaces the
   `kiroSymlinkSteering` helper + `kiroSteeringFiles` list with
   auto-discovery. Live-edit preserved.
3. Consumer commit message should reflect the factory bump,
   the kiro-steering migration, AND the scope-fix breaking
   change (sws skills / instructions / references disappear from
   HM scope — bug fix).

## Working-style memory captured this session

- Broadened "never propose upstream work" memory
  (`feedback_no_unsolicited_upstream_issues.md`): rule now covers
  proposing as well as filing.
- New memory `feedback_journal_before_acting.md`: write plan to
  markdown before code changes for non-trivial work, update when
  reality diverges.
- Existing memories unchanged.

### Live-edit rules (`fab4e5c`)

Shipped after the initial handoff. `ai.<cli>.rules.<name>.sourcePath`
unblocks clean migration of the consumer's 15 kiro steering files.
Two pivots from the plan captured in `docs/ai-rules-livelink-plan.md`
(test-harness `config.lib` stub + dropping `config` from devenv
callback after deadnix flag).

## Uncommitted state at handoff

Working tree clean. All changes committed. Branch ahead of origin
by 26 commits.
