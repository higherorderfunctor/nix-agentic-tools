# The markdown table-cell check: ONE definition, read by the prek hook in
# `config/repo-validation.nix`, by the fixture suite in
# `checks/markdown/markdown-table-cells-fixtures.nix`, and by the independent
# `tableCells` guard in `lib/generated.nix` for generated Markdown.
{pkgs}: let
  # rumdl finds header/delimiter mismatches; markdownlint finds excess body
  # cells. Both report MD056, but neither sees the other's case. An unescaped
  # pipe inside a code span is still a cell separator.
  markdownlintTablesConfig = pkgs.writeText "markdownlint-tables.jsonc" ''
    { "default": false, "MD056": true }
  '';

  markdownTableCells = import ../strict-shell-application.nix pkgs {
    name = "markdown-table-cells";
    text = ''
      # Run both tools so one invocation reports both forms of MD056.
      rc=0
      ${pkgs.ai.devTools.rumdl}/bin/rumdl check --enable MD056 --no-config --no-cache -- "$@" || rc=1
      ${pkgs.ai.devTools.markdownlint-cli2}/bin/markdownlint-cli2 \
        --config ${markdownlintTablesConfig} -- "$@" || rc=1
      if [ "$rc" -ne 0 ]; then
        # The single-quoted backticks below are literal Markdown examples.
        # shellcheck disable=SC2016
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
