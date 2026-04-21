# `ai.claude.marketplaces` + `ai.claude.outputStyles` — Route to Upstream

> **Status:** plan only, awaiting review.
>
> **Goal:** expose upstream HM `programs.claude-code`'s
> `marketplaces` and `outputStyles` options via our `ai.claude.*`
> surface so consumers can declare them through our module instead of
> reaching around it. Both are Claude-only (no Copilot/Kiro analog),
> so no cross-ecosystem design is needed — scope is deliberately
> narrow.

## Scope justification

- Consumer today uses a bespoke `installClaudePlugins` activation
  script in nixos-config to materialize Claude marketplaces. That's
  the direct thing our `ai.claude.marketplaces` option replaces.
- `outputStyles` is similar shape + cheap to wire at the same time.
- Both route to upstream as identity translations — our
  schema matches upstream's shape exactly, so translation has nothing
  to transform (same posture as today's `settings` / `plugins` — we declare our
  own type, upstream accepts the same shape, translation is `id`).
- Keeps the plan small and landable in one commit.

## Out of scope (tracked follow-ups, not this pass)

- **Typed schemas for marketplaces / outputStyles.** Same story as
  settings: upstream is freeform, we match. If we ever want opinionated
  structure, translation becomes non-identity. Not today.
- **Claude-side `hooks`, `agents`, `commands`.** Cross-ecosystem
  concerns, deserve their own cross-ecosystem design passes (top-level
  `ai.hooks`, `ai.agents`, `ai.commands` + per-CLI translation). This
  plan is explicitly Claude-only extras.
- **`ai.claude.lspServers`.** Cross-ecosystem; should land as
  `ai.lspServers` at the top level, not as a per-Claude option.
  Separate plan.
- **Migrating the consumer.** Different repo, out of scope here.

## Current state audit

- `packages/claude-code/lib/mkClaude.nix:22-52` declares Claude options:
  `context`, `plugins`, `settings`. No `marketplaces`, no
  `outputStyles`.
- Upstream HM `programs.claude-code.marketplaces`:
  ```
  type = attrsOf (either package path);
  default = {};
  ```
  Written into `.claude/settings.json.extraKnownMarketplaces` via
  upstream's `mkMarketplaceEntry`. Not a separate file write.
- Upstream HM `programs.claude-code.outputStyles`:
  (Need to verify type during implementation — likely
  `attrsOf (either lines path)` following the `mkContentOption` pattern
  used for `agents`, `commands`, `rules`. Written to
  `.claude/output-styles/<name>.md`.)
- Consumer has `installClaudePlugins` activation in nixos-config
  ai/default.nix — the `marketplaces` option lets them switch to
  declarative config.

## Plan

### 1. Verify upstream types

Read `/nix/store/...-source/modules/programs/claude-code.nix` around
the `marketplaces` and `outputStyles` option declarations to capture
their exact `type =` and `default =`. Record the types in this doc
under "Current state audit" before coding so the Nix compile-time
matches.

### 2. Add options to mkClaude.nix

In the shared `options = { ... }` block alongside `settings` / `plugins`:

```nix
marketplaces = lib.mkOption {
  type = with lib.types; attrsOf (either package path);
  default = {};
  description = ''
    Claude plugin marketplaces. Each entry is either a path to a
    marketplace directory or a package derivation. Routed to
    programs.claude-code.marketplaces; upstream writes them into
    ~/.claude/settings.json under extraKnownMarketplaces.
  '';
};

outputStyles = lib.mkOption {
  # Type verified in step 1.
  type = ...;
  default = {};
  description = ''
    Claude custom output style definitions. Attribute name becomes
    the style name; value is inline markdown or a path to a .md
    file. Routed to programs.claude-code.outputStyles;
    upstream writes them under ~/.claude/output-styles/.
  '';
};
```

### 3. Wire identity translation in HM block

Add to the `programs.claude-code = { ... }` attrset in mkClaude.nix
HM config:

```nix
inherit (cfg) marketplaces outputStyles;
```

Same posture as the existing `inherit (cfg) settings;` and
`plugins = lib.mkDefault cfg.plugins;` — identity translation because
upstream accepts the same shape we declare. Comment in the block
already covers the transitional-identity-translation rationale.

### 4. Devenv — skip both

- Upstream devenv `claude.code` doesn't expose either option per the
  earlier audit (only `enable`, `mcpServers`, `hooks`, `settingsPath`).
- `marketplaces` being settings.json-embedded means it could flow
  through the existing gap-write pathway. But it requires reshaping
  into the `extraKnownMarketplaces` schema, which is a Claude-specific
  translation. Not worth the complexity for a first pass.
- `outputStyles` writes to `~/.claude/output-styles/<name>.md` files
  in upstream HM. Devenv would need to replicate that file write, a
  gap fill similar to our rules emission. Also skipping.
- If a consumer later wants marketplaces or outputStyles in a devenv
  context, we'll open a follow-up plan.

### 5. Tests (module-eval)

Two tests, both HM-side, both asserting identity translation:

- `ai.claude.marketplaces.foo = ./somewhere;` →
  `config.programs.claude-code.marketplaces.foo == ./somewhere`.
- `ai.claude.outputStyles.my-style = "text";` →
  `config.programs.claude-code.outputStyles.my-style == "text"`.

Both small regression guards. Harness already stubs
`programs.claude-code = { ... with many options ... };`; need to add
the two new option declarations to `hmStubs` in
`checks/module-eval.nix` and to `hmStubModule` in
`lib/options-doc.nix` so the wiring lands without
"option does not exist" errors. (Same stub-extension pattern
documented as an implementation note in
`docs/ai-claude-settings-plan.md`.)

### 6. Plan.md bullet close-out

The existing bullet "Expose upstream HM claude-code options on
ai.claude" gets progress notes: marketplaces + outputStyles shipped
this pass; agents/commands/hooks/lspServers flagged as cross-ecosystem
follow-ups.

### 7. Commit

Single commit: `feat(claude): route ai.claude.marketplaces +
ai.claude.outputStyles to upstream`. Covers options, HM wiring, stub
extensions, tests, plan.md update.

## Size estimate

~40 lines factory + ~30 lines stubs + 2 tests + 1 plan.md edit + 1
commit.

## Review checklist

- [ ] Types for both options match upstream exactly.
- [ ] HM wiring uses `inherit` (identity translation) with no
      behavioral changes.
- [ ] Devenv intentionally left out (justified above).
- [ ] Both stubs (module-eval + options-doc) extended.
- [ ] Tests are regression guards, not deep behavior assertions.
- [ ] Plan.md "Expose upstream HM claude-code options" bullet updated
      with progress + remaining follow-ups.
