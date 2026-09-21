# Repository ownership and layout

**Settled baseline:** the package ownership redesign merged in
[PR #1633](https://github.com/higherorderfunctor/nix-agentic-tools/pull/1633) as
`3510a5dbc816a1598e0ff0c357c0c237dc78b267` on 2026-09-12. The operator accepted
this layout as the design to keep until a future redesign is explicitly
requested.

This guide describes the current structure.
[Workstream #1019](https://github.com/higherorderfunctor/nix-agentic-tools/issues/1019)
records the implementation and validation. The
[retired planning index](package-restructure.md) provides historical provenance
only.

Further regrouping of owners, reducing the `packages/` nesting, or extracting
overlays into another repository is not pending work under this redesign. Future
layout work starts from this baseline and its tests, with a new scope; old plans
and private fixtures do not reopen it. Package additions, updates, fixes, and
routine maintenance continue within the settled ownership model.

```text
packages/
  kiro-cli/                         One package owner
    packages/ai/
      kiro-cli/package.nix          Native package namespace
      kiro-cli-workflows/package.nix
    modules/
      devenv/default.nix            Consumer project configuration
      homeManager/default.nix       Consumer home configuration
    lib/
      default.nix                   Public helpers in their native namespace
      mkKiro.nix                    Private implementation helpers
      packaging.nix                 Owner-specific extraction/build machinery
    checks.nix                      Native check module entry point
    checks/
      module-eval.nix               Owner assertions for both backends
      kiro-wrapper-argv.nix         Runtime contracts
      fixtures/                     Owner test data
    registry.nix                    Update, cache, docs, architecture metadata
    sources.json                    Release pins
    extracted.json                  Measured upstream metadata
    docs/, patches/, src/           Supporting material when applicable
  agnix/
    packages/ai/
      agnix/package.nix
      lspServers/agnix-lsp/package.nix
      mcpServers/agnix-mcp/package.nix
    registry.nix
  delegate-sizing/
    packages/delegate-sizing-content/package.nix
    modules/, lib/, checks.nix, checks/
    fragments/, scripts/             Runtime-generated sizing skills
  stacked-workflows/
    packages/stacked-workflows-content/package.nix
    modules/, lib/, checks.nix, checks/
    docs/, fragments/, references/, skills/
checks/
  ai-fanout/, module-provenance/     Contracts spanning several owners
  facets/                           Native composition and relocation controls
  markdown/, packaging/, shell/     Repository and shared machinery checks
  <concern>/default.nix              Discovered workspace check module
lib/
  ai/                               Shared AI module engine
  facets/                           Discovery and native composition
  testing/                          Shared harnesses and check option schema
  packaging.nix                     Shared build/update helpers
config/                             Workspace policy and shared declarations
dev/                                Repository generation, tasks, and tooling
flake.nix                           Public assembly and workspace outputs
devenv.nix                          This repository's development environment
```

The outer owner name groups related work; the path below its `packages/`
directory defines the public package namespace. One owner can supply several
roles or major versions. Moving an owner does not rename those public paths. An
owner contains only the surfaces it needs.

Owners register consumer modules, public helpers, checks, and metadata locally.
The composer discovers them and rolls their contributions into the module
system. There is no central owner allowlist, package export list, or check
concatenation. Duplicate public leaves and check names fail with provenance.
Workspace check discovery stops at each concern's `default.nix`, keeping private
fixtures out of registration.

The shared test harness discovers the same backend modules as production.
Package check modules provide their own activation probes and small test
binaries where needed. Cross-package assertions stay under the relevant root
check concern. Repository-only devenv tasks and validation policy remain at the
workspace level.

Consumers use `overlays.default`. The flat flake outputs derive from native
package basenames; the former `modelcontextprotocol-all-mcps` and
`modelcontextprotocol-filesystem-mcp` names are now `all-mcps` and
`filesystem-mcp`. Compatibility aliases are intentionally absent. Consumer
repository updates are separate from this repository redesign.

For contribution contracts and the pitfalls that tests enforce, read
[Package ownership and native composition](../dev/fragments/facets/package-ownership.md).
