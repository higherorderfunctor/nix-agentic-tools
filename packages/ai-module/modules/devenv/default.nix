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
  duplicate = files.duplicate ["files2-apply" "files2-guard" "files2-inspect" "files2-prune" "files2-snapshot"];
  nativeFiles = builtins.attrNames config.files != [];
  # The observer's ownership: each plan path named by the option that declares
  # it (its layer-1 claim, else `ai.files2`), plus the old path's live paths
  # until chunk 12 removes it. Exact paths only; a `<dir>/**` entry is skipped.
  enabledKeys = builtins.filter (key: config.ai.files2.${key}.enable) (builtins.attrNames config.ai.files2);
  optionFor = path: let
    key = lib.findFirst (key: key == path || lib.hasPrefix "${key}/" path) path enabledKeys;
    claim = config.ai.files2Owners.${key} or [];
  in "ai.${lib.concatMapStrings (owner: "${owner}.") claim}files2.${builtins.toJSON key}";
  owned =
    lib.genAttrs (builtins.filter (path: !lib.hasSuffix "/**" path) (config.ai.deliveredPaths or [])) (path: "ai.*.files.${builtins.toJSON path}")
    // lib.genAttrs (map (item: item.path) files.plan) optionFor;
  observed = pkgs.writeText "files2-ai-observed.json" (builtins.toJSON {
    current = builtins.attrNames config.files ++ builtins.attrNames owned;
    # A consumer `copyMode` on an old-path link is a deliberate copy.
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
      files2-inspect = files.generatedEntry {
        after = ["materialized"];
        before = ["shell"];
        command = observe "inspect";
        showOutput = true;
      };
      files2-prune = files.prune;
      # Reads devenv's previous link list before its cleanup rewrites it.
      files2-snapshot = files.generatedEntry {
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
