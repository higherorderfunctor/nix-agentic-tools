{
  lib,
  pkgs,
  ...
}: let
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  fileFormats = ["json" "toml" "yaml"];
  plans = pkgs.writeText "files-value-plans.json" (builtins.toJSON valuePlans);
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  valuePlans = lib.genAttrs fileFormats (format:
    fileLib.normalize {
      backend = "hm";
      files =
        (lib.evalModules {
          modules = [
            ../modules/common.nix
            {
              ai.files."nested/settings" = {
                content.value = {owned = 1;};
                inherit format;
                method = "rw";
              };
            }
          ];
        }).config.ai.files;
      namespace = "renderer";
    });
in {
  checks.ai-module-files-rw-runtime = pkgs.runCommandLocal "ai-module-files-rw-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${python}/bin/python3 -I ${./rw.py} ${../lib/files}/engine.py ${plans}
    printf 'PASS: files rw runtime\n' > "$out"
  '';
}
