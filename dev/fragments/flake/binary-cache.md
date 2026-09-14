## Binary Cache Maintenance

> **Last verified:** 2026-09-13 — native package shards retain the Numtide
> substitution and Semble mirroring policy.
>
> **Settled — do not relitigate.** Full lineage:
> `git show b330b5af:dev/fragments/flake/binary-cache.md`.
>
> - **Numtide substitution must be a job-level `NIX_CONFIG`, never
>   `extra_nix_config` on the installer step or flake `nixConfig`.**
>   cachix-action's installer step exports `NIX_USER_CONF_FILES` pointing at a
>   conf that ASSIGNS `substituters` instead of extending it, discarding
>   `extra_nix_config` before anything builds — measured on run 31865858320,
>   with no numtide key present anywhere, CI included. Flake-level `nixConfig`
>   was tried and reverted first, since it would push numtide onto every
>   consumer; job-level `NIX_CONFIG` works because nix applies it after
>   cachix-action's conf, and it shows up in `nix config show` for verification.

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
runners only — as a job-level `NIX_CONFIG` on ci.yml's `build-packages` job, NOT
on the installer step, whose `extra_nix_config` cachix-action discards (see the
marker above for the measurement). On authenticated `main` builds, the shard
containing Semble pipes the realized Semble path to
`cachix push nix-agentic-tools`, mirroring its runtime closure into the project
cache. Do not add Numtide's cache to public `flake.nix` `nixConfig` or
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

This is separate from `devenv test` closure policy.
`ai.codex.programs.semble.enable = !isCI` keeps the interactive package out of
that cold runtime-test shell; it does not remove or weaken the flake check
above.
