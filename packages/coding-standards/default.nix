# Coding-standards content package — reusable coding standard fragments.
# Derivation: pkgs.coding-standards
# passthru provides eval-time access to typed fragment attrsets.
_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
  mkFrag = name:
    fragmentsLib.mkFragment {
      text = builtins.readFile ./fragments/${name}.md;
      description = "coding-standards/${name}";
      priority = 10;
    };
in {
  coding-standards =
    final.runCommand "coding-standards" {} ''
      mkdir -p $out/fragments
      cp ${./fragments}/*.md $out/fragments/
    ''
    // {
      passthru.fragments = {
        coding-standards = mkFrag "coding-standards";
        commit-convention = mkFrag "commit-convention";
        config-parity = mkFrag "config-parity";
        tooling-preference = mkFrag "tooling-preference";
        validation = mkFrag "validation";
      };
    };
}
