# Shared treefmt config — consumed by devenv.nix treefmt module.
# Each formatter handles specific file types (see inline comments).
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
      # `always` (reflow prose to printWidth), NOT `preserve`, and the
      # difference is load-bearing rather than cosmetic. Prettier treats an
      # inline code span as an UNBREAKABLE token: reflowing moves an
      # over-long span onto its own line and lets it overflow rather than
      # splitting it, and it JOINS any span that already straddles a
      # newline. So this setting makes `a `split\nspan`` structurally
      # impossible, and checks/formatting.nix turns that into a CI gate for
      # free. Under `preserve` the same defect merely persists — measured
      # at 369 spans across 66 files when this was flipped.
      #
      # That matters because these files are read as RAW markdown by agents
      # out of `.claude/rules/`, `.github/instructions/`, and
      # `.kiro/steering/`, never as rendered HTML. CommonMark does render a
      # split span correctly in the general case (the newline becomes a
      # space) — except where the break lands mid-token, which silently
      # corrupts the span. See checks/split-code-spans.py, the backstop for
      # the pathological cases a reflow cannot reach.
      #
      # KNOWN LIMIT — this setting LAUNDERS a mid-token break. Prettier
      # joins a split span by printing the span's CommonMark VALUE, and
      # that value already holds the space CommonMark put where the
      # newline was. So `programs.claude-code.\nmarketplaces` comes out as
      # `programs.claude-code. marketplaces`: one line, space intact,
      # defect preserved — and now with no newline for
      # checks/split-code-spans.nix to find. That class is NOT lintable
      # (measured: a glue-char-plus-space heuristic gives 96 hits, ~90%
      # legitimate), so it is prevented at authoring time by the
      # markdown-formatting fragment instead. 10 code-span and 22 prose
      # instances were cleaned up by hand in #590 and #591.
      #
      # FORMATTER CHOICE IS SETTLED — do not re-survey. Measured
      # 2026-07-29: no Rust-family markdown formatter joins a split span
      # at all. dprint-markdown `textWrap: always` reflows the paragraph
      # and keeps the newline INSIDE the span; deno fmt uses the same
      # engine; rumdl is a markdownlint clone with no reflow. Only
      # prettier and mdformat manage it, and mdformat joins WITHOUT
      # rewrapping (110-160 char lines) besides escaping `\<150` and
      # renumbering ordered lists. The fragment carries the table.
      #
      # printWidth is deliberately left at prettier's default of 80.
      # NOTE proseWrap also governs YAML folded/plain scalars, so
      # changing it reflows .github/** too — verify semantics by parsing
      # both revisions and diffing the loaded structures, not by eye.
      settings.proseWrap = "always";
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
    # phantom diff on a 145 KB file. The `<pkg>-package-lock.json` glob
    # matches devenv.nix's existing cspell exclusion, so the naming
    # convention is keyed on once and honoured by both.
    "*-package-lock.json"
    ".devenv/**"
    ".direnv/**"
    ".pre-commit-config.yaml"
    "overlays/sources/**"
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
    # `docs/**`; checks/markdown-scan.nix carries the matching scan
    # exclusion for BOTH prose scanners (split-code-spans and
    # doubled-words) — it used to live in checks/split-code-spans.nix
    # and moved when the second scanner started sharing the file set.
    "docs/plans/kiro-v3-research-raw/**"
    # Steering probe fixtures whose YAML SHAPE is the experiment. Two of
    # them carry a multi-line flow sequence that kiro's frontmatter parser
    # rejects — the rejection is the finding — and prettier normalizes both
    # into a shape that parses, silently deleting it. cspell already ignores
    # the sentinel markers via project terms; checks/markdown-scan.nix
    # carries the matching scan exclusion, and the probe README states why.
    # Renaming this directory touches THREE surfaces: this list,
    # checks/markdown-scan.nix, and dev/probes/kiro-steering/README.md. The
    # cspell terms are keyed on the sentinel words rather than the path, so a
    # rename deliberately does NOT touch them.
    "dev/probes/kiro-steering/fixture/**"
  ];
}
