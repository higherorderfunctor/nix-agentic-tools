{
  lib,
  pkgs,
  ...
}: let
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  copy = value: {
    "nested/file.txt" = {
      content.text = value;
      method = "ro";
    };
  };
  definitions =
    {
      copy = copy "declared";
      descendant = {
        "file/child" = {
          content.text = "child";
          method = "ro";
        };
      };
      disabled = {
        "nested/file.txt" = {
          enable = false;
          method = "ro";
        };
      };
      empty = {};
      executable = {
        file = {
          content.text = "executable";
          executable = true;
          method = "ro";
        };
      };
      imposedMode = {
        file = {
          content.text = "private";
          method = "ro";
          mode = "0400";
        };
      };
      run = {
        "nested/file.txt" = {
          content.run = ''
            printf 'run\n' >> "$FILES_RUN_LOG"
            printf declared
          '';
          method = "ro";
        };
      };
      source = {
        tree = {
          content.source = ./fixtures/a;
          method = "ro";
          recursive = true;
        };
      };
      updated = copy "updated";
    }
    // builtins.listToAttrs (map (mode: {
      name = "ownerRead-${mode}";
      value.file = {
        content.text = "readable";
        method = "ro";
        inherit mode;
      };
    }) ["0400" "0500"]);
  normalize = backend: files:
    fileLib.normalize {
      inherit backend;
      files = (lib.evalModules {modules = [../modules/common.nix {ai.files = files;}];}).config.ai.files;
      namespace = "runtime";
    };
  fixtures = lib.genAttrs ["devenv" "hm"] (backend: lib.mapAttrs (_: normalize backend) definitions);
  plan = pkgs.writeText "files-ro-plans.json" (builtins.toJSON fixtures);
in {
  checks.ai-module-files-ro-runtime = pkgs.runCommandLocal "ai-module-files-ro-runtime" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    FILES_BASH=${pkgs.bash}/bin/bash ${pkgs.python3}/bin/python3 -I ${./runtime.py} ${../lib/files}/engine.py ${plan}
    printf 'PASS: files ro runtime\n' > "$out"
  '';
}
