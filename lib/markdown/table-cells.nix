# The markdown table-cell check: ONE definition, read by the prek hook in
# `config/repo-validation.nix`, by the fixture suite in
# `checks/markdown/markdown-table-cells-fixtures.nix`, and by the `tableCells`
# guard in `lib/markdown/guards.nix`, for generated Markdown and consumer files.
{pkgs}: let
  inherit (pkgs) lib;
  # rumdl finds header/delimiter mismatches; markdownlint finds excess body
  # cells. Both report MD056, but neither sees the other's case.

  # The markdownlint half, through the library rather than the command, so a
  # markdownlint configuration file in the checked tree cannot turn MD056 off.
  # ./markdownlint-tables.mjs says what the command would read and why
  # `--config` is not enough.
  strictShellApplication = import ../strict-shell-application.nix pkgs;
  node = lib.getExe pkgs.nodejs;
  markdownlintTablesScript = pkgs.replaceVars ./markdownlint-tables.mjs {
    cli2 = "${pkgs.ai.devTools.markdownlint-cli2}/lib/node_modules/markdownlint-cli2/package.json";
  };
  markdownlintTables = strictShellApplication {
    name = "markdownlint-tables";
    text = ''
      exec ${node} ${markdownlintTablesScript} "$@"
    '';
  };

  # The rumdl half. OUR overlay packages, here and in the markdownlint half,
  # not `pkgs.rumdl` / `pkgs.markdownlint-cli2`: those are whatever the
  # nixpkgs pin happens to carry, and the point of absorbing both was to
  # track upstream on this repo's own sweep. `--no-config` keeps the checked
  # tree's configuration files out. `--no-cache`: rumdl otherwise writes
  # `.rumdl_cache/` into its working directory, whatever tree it is
  # checking, and the cache buys nothing at 0.04s.
  rumdlTables = strictShellApplication {
    name = "rumdl-tables";
    text = ''
      exec ${pkgs.ai.devTools.rumdl}/bin/rumdl check --enable MD056 --no-config --no-cache -- "$@"
    '';
  };

  markdownTableCells = strictShellApplication {
    name = "markdown-table-cells";
    text = ''
      if [ "$#" -eq 0 ]; then
        echo "usage: markdown-table-cells FILE..." >&2
        exit 2
      fi
      # Run BOTH before failing, so one commit reports every broken table
      # rather than only the first half of the class.
      rc=0
      ${lib.getExe rumdlTables} "$@" || rc=1
      ${lib.getExe markdownlintTables} "$@" || rc=1
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
        exit 1
      fi
    '';
  };
in {
  package = markdownTableCells;
  inherit markdownlintTables rumdlTables;
}
