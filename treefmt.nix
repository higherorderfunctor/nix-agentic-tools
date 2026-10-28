# Repository treefmt config. It imports the exported treefmt module, then adds the
# repository root, repository-only Rust formatter, and path-specific exclusions. Consumers: devenv.nix's treefmt
# module, the flake `formatter`, and checks/repository/formatting.nix. The
# exported module is also the default `ai.formatter`, so generated files use the
# same formatter programs and style without the repository-only exclusions.
{inputs}: {pkgs, ...}: {
  imports = [./lib/treefmt-module.nix];

  # Use flake.nix as the tree-root marker so `nix fmt` works in git
  # worktrees (where .git is a gitfile pointer, not a directory).
  # treefmt-nix's default is `.git/config`, which fails inside any
  # `git worktree add`-created tree. The update pipeline runs
  # `nix fmt` from per-input worktrees (see update-input.sh Phase 2.5),
  # so this default must be overridden.
  projectRootFile = "flake.nix";

  # Rust lives only in this repository, so its formatter stays out of the
  # exported consumer module and its large closure. Format the in-repo airlock
  # workspace with the toolchain selected by its recipe.
  programs.rustfmt = {
    enable = true;
    package = (import ./lib/toolchains.nix {inherit inputs;}).mkRustToolchain {
      inherit pkgs;
      channel = pkgs.ai.airlock.rustToolchainChannel;
      override = pkgs.ai.airlock.rustToolchainOverride;
      pname = pkgs.ai.airlock.pname;
    };
  };

  settings.global.excludes = [
    "*.lock"
    # Vendored npm lockfiles. npm — not biome — is the canonical
    # formatter: these are regenerated verbatim by
    # `npm install --package-lock-only` when the package is bumped, so
    # letting biome restyle them makes every regeneration a ~600-line
    # phantom diff on a 145 KB file. Include both standard package-lock.json
    # and prefixed lockfiles, matching config/repo-validation.nix's cspell exclusion.
    "*package-lock.json"
    ".devenv/**"
    ".direnv/**"
    ".pre-commit-config.yaml"
    "node_modules/**"
    "result/**"
    "result-*/**"
    # Verbatim research snapshot preserved for semantic retrieval (see
    # its README). The ungroomed sources carry mis-nested and
    # newline-straddling code spans, and prettier's span-joining mangles
    # identifiers when it repairs them (measured: `KIRO_KAS_NODE_PATH`
    # came out `KIRO*KAS_NODE_PATH`), which breaks exact-identifier
    # search — the directory's whole purpose. cspell already ignores
    # `docs/**`; checks/markdown/markdown-scan.nix carries the matching scan
    # exclusion for BOTH prose scanners (split-code-spans and
    # doubled-words) — it used to live in checks/markdown/split-code-spans.nix
    # and moved when the second scanner started sharing the file set.
    "docs/plans/kiro-v3-research-raw/**"
    # Steering probe fixtures whose YAML SHAPE is the experiment. Two of
    # them carry a multi-line flow sequence that kiro's frontmatter parser
    # rejects — the rejection is the finding — and prettier normalizes both
    # into a shape that parses, silently deleting it. cspell already ignores
    # the sentinel markers via project terms; checks/markdown/markdown-scan.nix
    # carries the matching scan exclusion, and the probe README states why.
    # Renaming this directory touches THREE surfaces: this list,
    # checks/markdown/markdown-scan.nix, and dev/probes/kiro-steering/README.md. The
    # cspell terms are keyed on the sentinel words rather than the path, so a
    # rename deliberately does NOT touch them.
    "dev/probes/kiro-steering/fixture/**"
    # CodeQL environment fixtures whose JavaScript SHAPE is what the query is
    # tested on: bracket keys, assignments inside expressions, a lone block, a
    # one-line minified chunk, `.d.ts` beside `.js`. biome rejects two of the
    # shapes outright and rewrites the rest; the expected-failures files cite
    # line numbers in them. The guard reads expected.json through `jq -S`.
    "packages/kimchi/checks/fixtures/codeql-environment/**"
  ];
}
