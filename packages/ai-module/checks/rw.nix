{
  lib,
  pkgs,
  ...
}: let
  files2 = import ../lib/files/default.nix {inherit lib pkgs;};
  files2Formats = ["json" "toml" "yaml"];
  plans = pkgs.writeText "files2-value-plans.json" (builtins.toJSON valuePlans);
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  valuePlans = lib.genAttrs files2Formats (format:
    files2.normalize {
      backend = "hm";
      files =
        (lib.evalModules {
          modules = [
            files2.module
            {
              files2."nested/settings" = {
                content.value = {owned = 1;};
                inherit format;
                method = "rw";
              };
            }
          ];
        }).config.files2;
      namespace = "renderer";
    });
in {
  checks.files2-rw-runtime = pkgs.runCommandLocal "files2-rw-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 -I ${./rw.py} ${../lib/files}/engine.py ${plans}
    printf 'PASS: files2 rw runtime\n' > "$out"
  '';
}
