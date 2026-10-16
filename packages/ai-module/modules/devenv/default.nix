{
  config,
  lib,
  options,
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
  targetFile = pkgs.writeText "files-ai-native.json" (builtins.toJSON nativeTargets);
  copyOverride = lib.findFirst (path: builtins.hasAttr path config.files && config.files.${path}.copyMode != "symlink") null (map (item: item.path) files.plan);
  duplicate = files.duplicate ["files-apply" "files-guard" "files-inspect" "files-prune" "files-snapshot"];
  nativeFiles = builtins.attrNames config.files != [];
  # The observer's ownership: each plan path named by the option that declares
  # it (its layer-1 claim, else `ai.files`). Recursive entries use their
  # expanded leaf paths.
  enabledKeys = builtins.filter (key: config.ai.files.${key}.enable) (builtins.attrNames config.ai.files);
  optionFor = path: let
    key = lib.findFirst (key: key == path || lib.hasPrefix "${key}/" path) path enabledKeys;
    claim = config.ai.filesOwners.${key} or [];
  in "ai.${lib.concatMapStrings (owner: "${owner}.") claim}files.${builtins.toJSON key}";
  owned = lib.genAttrs (map (item: item.path) files.plan) optionFor;
  observed = pkgs.writeText "files-ai-observed.json" (builtins.toJSON {
    current = builtins.attrNames config.files ++ builtins.attrNames owned;
    links = lib.mapAttrs (name: file: {
      option = owned.${name};
      source = "${file.file}";
    }) (lib.filterAttrs (name: file: owned ? ${name} && file.copyMode == "symlink") config.files);
    inherit owned;
  });
  observe = phase: ''${pkgs.python3}/bin/python3 -I ${../../lib/files}/observe.py ${phase} "$DEVENV_ROOT" "$DEVENV_STATE" ${observed}'';
  # devenv fails on a dependency naming an absent task, so apply names the
  # guard only when links emit it.
  guarded = files.links != [];
  generated =
    {
      # Reports what devenv did not deliver; devenv hides a passing task's output.
      files-inspect = files.generatedEntry {
        after = ["materialized"];
        before = ["shell"];
        command = observe "inspect";
        showOutput = true;
      };
      files-prune = files.prune;
      # Reads devenv's previous link list before its cleanup rewrites it.
      files-snapshot = files.generatedEntry {
        after = [];
        before = [];
        beforeNodes = {
          devenv = ["devenv:files:cleanup"];
          hm = [];
        };
        command = observe "snapshot";
      };
    }
    // lib.optionalAttrs (files.plan != []) {
      files-apply = files.generatedEntry {
        after = ["files"] ++ lib.optionals files.usesRun ["secrets"];
        afterNodes = {
          devenv = lib.optional guarded "ai:files-guard" ++ ["ai:files-prune"];
          hm = [];
        };
        before = ["materialized"];
        command = files.phase "apply";
      };
    }
    // lib.optionalAttrs guarded {
      files-guard = files.generatedEntry {
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
  config = lib.mkMerge [
    {
      files = files.native;
      tasks = assert lib.assertMsg (duplicate == null) "ai.activation.${duplicate}: reserved generated entry";
      assert lib.assertMsg (copyOverride == null) "ai.files.\"${copyOverride}\": native copyMode override refused";
        import ../../lib/lower-devenv.nix {inherit lib;} {
          entries = generated // config.ai.activation;
          inherit nativeFiles;
          secretNodes = config.ai.activationOrder.secretNodes;
        };
    }
    # Repository formatting never rewrites a delivered file. A backend without
    # treefmt has nothing to exclude.
    (lib.optionalAttrs (options ? treefmt) {
      treefmt.config.settings.global.excludes = lib.mkIf config.treefmt.enable (lib.mkAfter config.ai.deliveredPaths);
    })
  ];
}
