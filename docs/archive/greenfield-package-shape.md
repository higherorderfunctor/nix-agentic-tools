# Greenfield Package Shape

> **Status:** architectural direction, not yet executed. Captured from grill 2
> (2026-05-04) when discussing the (D) feasibility pilot. Records what the
> project would look like if rebuilt today, given what we know now about the
> barrel-walker trade-offs.

## Why this doc exists

The current `packages/<name>/default.nix` convention is a **mixed-eval barrel**
— a literal attrset where some keys are paths (data), some are deferred imports
(functions evaluated at use site), and some are evaluated values. This works but
pushes real friction onto consumers:

- Reading a barrel can't tell you which keys are data vs functions without
  opening each file.
- Code that needs `lib`/`pkgs` at construction time becomes a
  `mkX = import ./...` deferred constructor that consumers must call manually
  with the right args.
- Scope mechanics (`callPackage`, `makeScope`) get reconstructed inside slices
  instead of being available at the project root.

This is a deliberate trade-off (multi-facet packages don't fit nixpkgs-style
pure-derivation `callPackage` cleanly), but with hindsight there's a cleaner
shape that preserves the multi-facet benefits without the mixed-eval friction.

## The shape

Uniform value semantics: every key in the barrel is a **path**. Each facet has a
**dedicated file** (or directory). The flake-level walker decides how to
_consume_ each path based on its key, not on the file's eval shape.

```
packages/<name>/
├── default.nix          # thin barrel: { package = ./package.nix; module.* = ./...; lib = ./lib; ... }
├── package.nix          # callPackage-style function: {lib, stdenv, ...}: stdenv.mkDerivation {...}
├── module-hm.nix        # NixOS-module function: {config, lib, pkgs, ...}: { options = ...; config = ...; }
├── module-devenv.nix    # devenv-module function (same shape)
├── update.nix           # merge-up contribution: { config.update.targets.<name> = {...}; }
├── lib/                 # directory of lib helpers (each a {lib, ...}: function)
│   └── default.nix
├── docs/                # documentation data (markdown, paths)
└── fragments/           # fragment data
```

`default.nix` becomes a tiny stitcher:

```nix
{
  package = ./package.nix;
  module.homeManager = ./module-hm.nix;
  module.devenv = ./module-devenv.nix;
  update = ./update.nix;
  lib = ./lib;
  docs = ./docs;
  fragments = ./fragments;
}
```

Every value is a path. No deferred constructors. No mixed eval.

## What changes at the consumption layer

`flake.nix`'s `collectFacet` walker becomes responsible for applying the **right
wrapper** to each facet path:

| Facet                | How the walker uses the path                                       |
| -------------------- | ------------------------------------------------------------------ |
| `package`            | `pkgs.callPackage path {}` inside the overlay                      |
| `module.homeManager` | `imports = [path];` in `homeManagerModules.default`                |
| `module.devenv`      | `imports = [path];` in `devenvModules.nix-agentic-tools`           |
| `update`             | added to the merge-up modules list for `config.update.targets`     |
| `lib`                | `import path {inherit lib;}` (deeply-merged into `flake.lib.ai.*`) |
| `docs`               | passed as data to the doc-gen pipeline                             |
| `fragments`          | passed as data to the fragment pipeline                            |

The walker becomes the **single place** that knows how to consume each facet
shape. Today that knowledge is scattered across flake.nix, packages, and
per-package barrels.

## Why this is cleaner

1. **Uniform semantics.** Every barrel value is a path. No exception cases, no
   "is this a function or data?" guessing.
2. **Dedicated facet files.** `package.nix`, `module-hm.nix`, `update.nix` —
   names map 1:1 to consumer wrappers. Reading the filename tells you the role.
3. **Idiomatic nixpkgs interfaces.** `package.nix` is a `callPackage`-style
   function — the bedrock pattern. NixOS modules use the standard
   `{config, lib, pkgs, ...}: {...}` shape. Anyone with Nix experience reads
   them at a glance.
4. **Scope where it belongs.** The overlay/walker provides callPackage scope for
   derivations; the module system provides evalModules scope for module merge;
   lib helpers are pure `{lib, ...}: {...}` functions. No project-internal
   deferred constructor pattern needed.
5. **Aligned with overlay dissolution.** Per
   `monorepo-restructure-assessment.md` §11, `overlays/<name>.nix` files are
   slated to dissolve into owning packages. The greenfield shape's `package.nix`
   IS that dissolution target — migration becomes a
   `cp overlays/<name>.nix packages/<name>/package.nix` plus a barrel-key add.

## What it doesn't change

- The barrel walker pattern itself stays. Every package still has a
  `default.nix` barrel.
- Multi-facet aggregation stays — one directory per cohesive package/slice
  topic.
- Slice-nav direction (one dir per topic, scopes inside slices) is unchanged.
  Greenfield is about the SHAPE inside each package/slice, not the inter-slice
  composition.
- Existing factory and helpers (`mkAiApp`, `mkMcpServer`, etc.) carry over
  verbatim — only their consumers' arg-passing conventions tighten.

## What it costs

A one-time global refactor of `packages/default.nix` and `flake.nix`'s
`collectFacet`. Each existing per-package barrel gets simplified (fewer
mixed-eval keys). Each existing `overlays/<name>.nix` migrates to
`packages/<name>/package.nix` and gets adjusted from
`final: prev: {<name> = ...;}` shape to direct `callPackage`-style. ~12-20
packages, ~8-16h aggregate based on past similar refactors in this repo.

The `mkAiApp` factory record (`packages/<name>/lib/mk<Name>.nix`) stays mostly
as-is — it's already a function consumed via deferred import. The tightening is
at the _barrel_ level, not the factory.

## Open questions for when this gets executed

1. Where do per-platform `<name>-sources.json` sidecars live — alongside
   `package.nix` (probably yes, that's where they conceptually belong) or in a
   `sources/` subdir?
2. Does the walker need to support **multiple** `module.*` contributions per
   package (e.g. a package that contributes two HM submodules), or is
   one-per-facet sufficient?
3. How does the merge-up walker (`config.update.targets` and future
   `config.<concern>.<package>` namespaces) discover contributions — by walking
   barrel `update` keys, or by filesystem-walking `update.nix` files? Filesystem
   walk is simpler but loses the barrel's static introspection benefit.

## Where this fits with current pilots

- The mcp-servers pilot (`docs/archive/mcp-servers-pilot-plan.md`) tests
  composition mechanics (`makeScope`, `packagesFromDirectoryRecursive`,
  `evalModules` merge-up) regardless of barrel shape. Findings transfer to
  either shape.
- The greenfield refactor is the END SHAPE the project converges on. Whether to
  pilot in greenfield shape directly or migrate later is a sequencing decision
  recorded in `docs/archive/mcp-servers-pilot-plan.md` and discussed in grill 2.
