{
  config,
  lib,
  pkgs,
  ...
}: let
  files = import ../../lib/files/backend.nix {inherit lib pkgs;} {
    backend = "devenv";
    inherit config;
    root = "$DEVENV_ROOT";
    stateRoot = "$DEVENV_STATE/nix-agentic-tools";
  };
  nativeTargets = builtins.listToAttrs (map (item: {
      name = item.path;
      value = "${config.files.${item.path}.file}";
    })
    files.links);
  targetFile = pkgs.writeText "files2-ai-native.json" (builtins.toJSON nativeTargets);
  copyOverride = lib.findFirst (path: builtins.hasAttr path config.files && config.files.${path}.copyMode != "symlink") null (map (item: item.path) files.plan);
  duplicate = files.duplicate ["files2-apply" "files2-guard" "files2-prune"];
  nativeFiles = builtins.attrNames config.files != [];
  # devenv fails on a dependency naming an absent task, so apply names the
  # guard only when links emit it.
  guarded = files.links != [];
  generated =
    {files2-prune = files.prune;}
    // lib.optionalAttrs (files.plan != []) {
      files2-apply = files.generatedEntry {
        after = ["files"] ++ lib.optionals files.usesRun ["secrets"];
        afterNodes = {
          devenv = lib.optional guarded "ai2:files2-guard" ++ ["ai2:files2-prune"];
          hm = [];
        };
        before = ["materialized"];
        command = files.phase "apply";
      };
    }
    // lib.optionalAttrs guarded {
      files2-guard = files.generatedEntry {
        after = ["linkCheck"];
        before = ["files"];
        beforeNodes = {
          devenv = lib.optional nativeFiles "devenv:files";
          hm = [];
        };
        command = ''${pkgs.python3}/bin/python3 -I ${../../lib/files}/guard.py --root "$DEVENV_ROOT" --targets ${targetFile}'';
      };
    };
in {
  imports = [../common.nix];
  config = {
    files = files.native;
    tasks = assert lib.assertMsg (duplicate == null) "ai.activation2.${duplicate}: reserved generated entry";
    assert lib.assertMsg (copyOverride == null) "ai.files2.\"${copyOverride}\": native copyMode override refused";
      import ../../lib/lower-devenv.nix {inherit lib;} {
        entries = generated // config.ai.activation2;
        inherit nativeFiles;
        secretNodes = config.ai.activation2Order.secretNodes;
      };
  };
}
