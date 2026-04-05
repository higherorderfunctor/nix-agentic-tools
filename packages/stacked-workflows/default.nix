# Stacked-workflows content package — skills, references, fragments.
# Derivation: pkgs.stacked-workflows-content
# passthru provides eval-time access to fragments, references, and skills.
_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
in {
  stacked-workflows-content =
    final.runCommand "stacked-workflows-content" {} ''
      mkdir -p $out/{fragments,references,skills}
      cp -r ${./fragments}/. $out/fragments/
      cp -r ${./references}/. $out/references/
      cp -r ${./skills}/. $out/skills/
    ''
    // {
      passthru = {
        fragments = {
          routing-table = fragmentsLib.mkFragment {
            text = builtins.readFile ./fragments/routing-table.md;
            description = "Stacked workflow skill routing table";
          };
        };
        referencesDir = ./references;
        skillsDir = ./skills;
      };
    };
}
