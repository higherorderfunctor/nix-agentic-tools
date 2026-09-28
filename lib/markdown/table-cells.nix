# The markdown table-cell check: ONE definition, read by the prek hook in
# `config/repo-validation.nix` and by the fixture suite in
# `checks/markdown/markdown-table-cells-fixtures.nix`.
{pkgs}: let
  shellStrict = import ../../config/shell-strict.nix;

  # Markdown TABLE CELL COUNTS. Two linters, deliberately, and the pairing is
  # the whole point — see the disjoint coverage table below before "deduplicating"
  # them.
  #
  # THE DEFECT. A GFM table is only a table when the header row and the
  # delimiter row have the same number of cells. Disagree and remark stops
  # seeing a table at all, `proseWrap = "always"` reflows the block as prose,
  # and it renders as a wall of pipes. It reached main once
  # (`dev/references/agnix.md`) and stayed, because the `<!-- prettier-ignore -->`
  # that someone added to quiet the formatter also hid it from
  # `checks.formatting` entirely.
  #
  # THE CAUSE is almost always one unescaped pipe. A row is split into cells at
  # BLOCK level, before inline parsing, so a backtick gives a pipe no
  # protection: writing `|| true` in a cell silently produces extra cells.
  # Escape it (`\|\| true`) and it is one cell again.
  #
  # WHY BOTH TOOLS. They share the rule NUMBER and cover disjoint halves of it,
  # which is exactly the trap that makes one of them look redundant. Measured:
  #
  #                                        rumdl MD056   markdownlint MD056
  #   cause: valid table, excess body cell      no             YES
  #   break: header/delimiter disagree          YES            no
  #
  # markdownlint goes blind on the break because its parser stops recognizing a
  # table, so its MD056 has nothing left to check. rumdl goes blind on the
  # cause. Drop either and half the class stops being caught.
  #
  # ORDER IS BY SPEED, primary first. Measured over this corpus with only MD056
  # enabled: rumdl 0.04s, markdownlint 8.2s (0.00s vs 0.19s on a single file).
  # rumdl is the Rust primary and is effectively free; markdownlint is the Node
  # backup that exists solely to cover the gap above, and its cost is paid only
  # for that.
  #
  # NOT a formatter question. `dev/fragments/markdown-formatting/` records that
  # no Rust markdown formatter joins a split inline code span, which is why
  # prettier owns formatting and keeps owning it. This is the LINTER slot beside
  # `doubled-words` and `split-code-spans`, and it reopens none of that.
  markdownlintTablesConfig = pkgs.writeText "markdownlint-tables.jsonc" ''
    { "default": false, "MD056": true }
  '';

  markdownTableCells = pkgs.writeShellApplication {
    name = "markdown-table-cells";
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = ''
      ${shellStrict.shoptHeader}
      # Both tools exit non-zero on a finding. Run BOTH before failing, so one
      # commit reports every broken table rather than only the first half of
      # the class.
      rc=0
      # OUR overlay packages, not `pkgs.rumdl` / `pkgs.markdownlint-cli2` —
      # those are whatever the nixpkgs pin happens to carry, and the point
      # of absorbing both was to track upstream on this repo's own sweep.
      ${pkgs.ai.devTools.rumdl}/bin/rumdl check --enable MD056 --no-config -- "$@" || rc=1
      ${pkgs.ai.devTools.markdownlint-cli2}/bin/markdownlint-cli2 \
        --config ${markdownlintTablesConfig} -- "$@" || rc=1
      if [ "$rc" -ne 0 ]; then
        printf '%s\n' >&2 \
          "" \
          "A markdown table needs the SAME cell count in its header row and its" \
          "delimiter row, and no row may carry more cells than the header (the" \
          "excess is silently dropped on render)." \
          "" \
          "The usual cause is one unescaped pipe. A row is split into cells BEFORE" \
          "inline parsing runs, so a backtick gives a pipe no protection: writing" \
          "a shell operator in a cell quietly adds cells. Escape it." \
          "" \
          # The backticks are LITERAL — these two lines show a markdown code
          # span, which is exactly the construct that causes the defect. Single
          # quotes are what keeps them literal; shellcheck flags SC2016 on any
          # single-quoted backtick in case a command substitution was meant.
          # shellcheck disable=SC2016
          '  broken:  | id | `|| true` on the hook |' \
          '  fixed:   | id | `\|\| true` on the hook |'
      fi
      exit "$rc"
    '';
  };
in {
  package = markdownTableCells;
  markdownlintConfig = markdownlintTablesConfig;
}
