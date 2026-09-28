# Shared treefmt config. Consumers: devenv.nix's treefmt module, the flake
# `formatter`, checks/repository/formatting.nix, and dev/house-markdown.nix,
# which formats the Markdown `ai.*` generates for this repository inside its
# delivery tree. Each formatter handles specific file types (see inline
# comments).
{
  # Use flake.nix as the tree-root marker so `nix fmt` works in git
  # worktrees (where .git is a gitfile pointer, not a directory).
  # treefmt-nix's default is `.git/config`, which fails inside any
  # `git worktree add`-created tree. The update pipeline runs
  # `nix fmt` from per-input worktrees (see update-input.sh Phase 2.5),
  # so this default must be overridden.
  projectRootFile = "flake.nix";

  programs = {
    # Nix: *.nix
    alejandra.enable = true;
    # PRIMARY formatter (user pref: biome over prettier). biome owns JS/TS/JSX/
    # JSON/CSS via its default treefmt globs; prettier is excluded from those in
    # settings.formatter below so the two never format the same file.
    biome = {
      enable = true;
      settings.formatter.indentStyle = "space";
      settings.formatter.indentWidth = 2;
    };
    # Only the types biome can't format (markdown/yaml/scss/html/vue/json5) —
    # scoped via settings.formatter.prettier.excludes.
    prettier = {
      enable = true;
      # The house prose style (`proseWrap = "always"`) and why: one definition,
      # shared with the default `ai.markdown.formatter`.
      settings = import ./lib/markdown/prose-style.nix;
    };
    # Shell: *.sh, *.bash
    shfmt.enable = true;
    # TOML: *.toml
    taplo.enable = true;
  };

  settings.formatter = {
    # Prefer biome: it owns JS/TS/JSX/JSON/CSS via its default globs. Exclude
    # those from prettier so the two never format the same file — they disagree
    # on constructs like a `new (x) => {…}` ctor type, which makes
    # `treefmt --fail-on-change` loop with an empty git diff. Note: treefmt-nix
    # `includes` APPEND to a formatter's defaults (they do not replace), so the
    # scoping has to be done with `excludes`. prettier keeps only what biome
    # can't format (markdown/yaml/scss/html/vue/json5).
    prettier.excludes = [
      "*.cjs"
      "*.css"
      "*.js"
      "*.json"
      "*.jsx"
      "*.mjs"
      "*.ts"
      "*.tsx"
    ];
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
    # Sentinel-tip scratch files. Prettier's markdown handler
    # mangles Nix globs like `modules/devenv/*.nix` into
    # `modules/devenv/_.nix` (it reads `*...*` as italic and
    # garbles the replacement), and re-indents deliberately
    # hand-formatted lists. These files are cspell-excluded
    # and never merge to main — leave them as-authored.
    "docs/plan.md"
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
  ];
}
