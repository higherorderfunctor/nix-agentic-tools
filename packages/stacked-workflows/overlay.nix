# Stacked-workflows content package — skills, references, fragments.
# Derivation: pkgs.stacked-workflows-content
# passthru provides eval-time access to fragments, references, and skills.
_: final: _prev: let
  inherit (final) lib;
  fragmentsLib = import ../../lib/fragments.nix {inherit lib;};

  # Filter out devenv/activation cruft that can accumulate inside
  # source skill directories. Pattern: `<32-lowercase-alnum>-<name>`
  # (a Nix store path basename) — these appear as dangling symlinks
  # when a stale devenv activation drops store-linked state into
  # the source tree. Since Nix's path import copies the working
  # tree verbatim (no .gitignore respect), we filter them out here
  # so they never enter the derivation output.
  skillsSource = builtins.path {
    name = "stacked-workflows-skills";
    path = ./skills;
    filter = path: _type: let
      base = baseNameOf path;
    in
      builtins.match "[0-9a-z]{32}-.+" base == null;
  };
in {
  stacked-workflows-content =
    final.runCommand "stacked-workflows-content" {} ''
      mkdir -p $out/{fragments,references,skills}
      cp -r ${./fragments}/. $out/fragments/
      cp -r ${./references}/. $out/references/
      cp -r ${skillsSource}/. $out/skills/
    ''
    // {
      passthru = {
        fragments = {
          routing-table = fragmentsLib.mkFragment {
            text = builtins.readFile ./fragments/routing-table.md;
            description = "Stacked workflow skill routing table";
            source = "packages/stacked-workflows/fragments/routing-table.md";
            priority = 10;
          };
        };
        referencesDir = ./references;
        skillsDir = skillsSource;
      };
    };
}
