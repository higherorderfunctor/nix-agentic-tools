## Binary Cache Maintenance

> **Last verified:** 2026-08-14 (commit pending — Semble's nixpkgs AWK and jq
> grammar paths remain consumer-owned inputs supplied by the nixpkgs Cachix
> follow, while its grammar/path-mapping-patched Python derivation is built only
> by the unauthenticated check job and cannot enter the public cache). Prior:
> 2026-08-02 (commit pending — records Semble's external pinned-package
> exception: Numtide substitution is CI-only and accepted main builds are
> mirrored into the public project cache without exposing the upstream cache in
> consumer flake/devenv configuration).

When adding or removing flake inputs, check whether the input has a public
Cachix cache. If so, add it to:

- `flake.nix` `nixConfig.extra-substituters` and
  `nixConfig.extra-trusted-public-keys`
- `devenv.nix` `cachix.pull`

Current public consumer cache: `nix-agentic-tools`. The `follows` pattern for
nixpkgs is intentional — do not remove it to chase upstream cache hits unless
the input provides pre-built binaries independent of nixpkgs.

Semble is the deliberate exception. The unfollowed `llm-agents` input supplies
an already-built package whose exact derivation is part of this repository's
public contract. Keep `cache.numtide.com` and its key on the CI package-build
runners only. Authenticated `main` builds explicitly pipe the realized Semble
path to `cachix push nix-agentic-tools`, mirroring its runtime closure into the
project cache. Do not add Numtide's cache to public `flake.nix` `nixConfig` or
`devenv.nix` `cachix.pull`; consumers should need only the project cache.

Extra Semble grammars already in nixpkgs remain direct consumer-owned
`pkgs.tree-sitter-grammars` inputs. Do not re-export them from this flake:
Cachix's nixpkgs follow already supplies those store paths. A future custom
grammar absent from nixpkgs must be exposed as a flake package so the
authenticated package matrix publishes it. The Semble package patched to load
the selected grammars is deliberately NOT a package output: the
`module-semble-extra-grammars-load` flake check builds it in the read-only
Cachix job, parses real AWK and jq samples, and exercises mapped-file discovery
and language selection. This proves customization without publishing a
grammar-set-specific Semble derivation.

This is separate from `devenv test` closure policy. `semble.enable = !isCI`
keeps the interactive package out of that cold runtime-test shell; it does not
remove or weaken the flake check above.
