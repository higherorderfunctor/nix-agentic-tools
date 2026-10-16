{
  harness,
  inputs,
  lib,
  pkgs,
  ...
}: let
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
  evaluate = files: native:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        harness.devenvStubs
        ../modules/devenv/default.nix
        {ai.activationOrder.secretNodes = ["vault:ready"];}
        {ai.files = files;}
        {files = native;}
      ];
    }).config;
  active = evaluate {
    "copy.txt" = {
      content.text = "copy";
      method = "ro";
    };
    "links/a.txt".content.text = "link";
    secret = {
      content.run = ''${pkgs.coreutils}/bin/cat "$DEVENV_ROOT/provider"'';
      method = "ro";
    };
    tree = {
      content.source = ./fixtures/a;
      recursive = true;
    };
  } {};
  copyOnly = evaluate {
    "copy.txt" = {
      content.text = "copy";
      method = "ro";
    };
  } {};
  # The directory symlink `link` is delivered as one link, not walked into.
  linkedStore = "${./fixtures}";
  linked = evaluate {
    linked = {
      content.source = linkedStore;
      recursive = true;
    };
  } {};
  empty = evaluate {} {};
  nativeOnly = evaluate {} {external.source = ../docs/DESIGN.md;};
  cleanup =
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        "${inputs.devenv}/src/modules/files.nix"
        {
          options = {
            devenv.root = lib.mkOption {type = lib.types.str;};
            devenv.state = lib.mkOption {type = lib.types.str;};
            tasks = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};
          };
          config = {
            _module.check = false;
            devenv.root = "__ROOT__";
            devenv.state = "__STATE__";
          };
        }
      ];
    }).config.tasks."devenv:files:cleanup".exec;
  plan = fileLib.normalize {
    backend = "devenv";
    files = active.ai.files;
    namespace = "ai";
  };
  targets = lib.mapAttrs (_: item: "${item.file}") active.files;
  overrideCases = lib.concatMap (method:
    map (copyMode: {
      inherit copyMode method;
      result = builtins.tryEval (builtins.deepSeq
        (evaluate {
            "owned.txt" = {
              content.value.owned = 1;
              format = "json";
              inherit method;
            };
          } {
            "owned.txt" =
              {inherit copyMode;}
              // lib.optionalAttrs (method != "symlink") {source = ../docs/DESIGN.md;};
          }).tasks
        true);
    }) ["copy" "seed"])
  ["ro" "rw" "symlink"];
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  # Every task an absent entry would have anchored must point past it.
  check = config: expectedFiles: emitted: linkCheckTo: linkedFrom: applyAfter: let
    inherit (config) tasks;
  in
    lib.optional (builtins.attrNames config.files != expectedFiles) "native files"
    ++ lib.optional (builtins.filter (lib.hasPrefix "ai:files-") (builtins.attrNames tasks) != lib.sort builtins.lessThan (emitted ++ ["ai:files-inspect" "ai:files-linked" "ai:files-ready" "ai:files-snapshot"])) "emitted entries"
    ++ lib.optional (tasks."ai:link-check".before != [linkCheckTo]) "link check target"
    ++ lib.optional (tasks."ai:files-linked".after != [linkedFrom]) "files linked"
    ++ lib.optional ((tasks."ai:files-apply".after or null) != applyAfter) "apply dependencies"
    ++ lib.optional (tasks."ai:files-prune".before != ["ai:link-check"]) "prune edge";
  failures =
    check active ["links/a.txt" "tree/b/c.md"] ["ai:files-apply" "ai:files-guard" "ai:files-prune"] "ai:files-guard" "devenv:files" ["ai:files-linked" "vault:ready" "ai:files-guard" "ai:files-prune"]
    ++ check copyOnly [] ["ai:files-apply" "ai:files-prune"] "ai:files-linked" "ai:link-check" ["ai:files-linked" "ai:files-prune"]
    ++ check empty [] ["ai:files-prune"] "ai:files-linked" "ai:link-check" null
    ++ check nativeOnly ["external"] ["ai:files-prune"] "devenv:files" "devenv:files" null
    ++ lib.optional (active.tasks."ai:files-guard".after != ["ai:link-check"] || active.tasks."ai:files-guard".before != ["ai:files-linked" "devenv:files"]) "guard edges"
    ++ lib.optional (lib.mapAttrs (_: item: "${item.source}") (lib.filterAttrs (name: _: lib.hasPrefix "linked/link" name) linked.files) != {"linked/link" = "${linkedStore}/link";} || !linked.files ? "linked/a/b/c.md") "directory symlink leaf"
    ++ lib.concatMap (case: lib.optional case.result.success "native ${case.copyMode} override for ${case.method}") overrideCases;
  fixtureJson = builtins.toJSON {
    active = {
      apply = active.tasks."ai:files-apply".exec;
      guard = active.tasks."ai:files-guard".exec;
      links = targets;
      inherit plan;
      planPath = "${pkgs.writeText "files-ai-plan.json" (builtins.toJSON plan)}";
      prune = active.tasks."ai:files-prune".exec;
      targetPath = "${pkgs.writeText "files-ai-native.json" (builtins.toJSON targets)}";
    };
    empty = {
      planPath = "${pkgs.writeText "files-ai-plan.json" "[]"}";
      prune = empty.tasks."ai:files-prune".exec;
    };
    inherit cleanup;
    python = "${python}";
  };
  fixture = pkgs.writeText "ai-module-files-devenv.json" fixtureJson;
in {
  checks.ai-module-files-devenv = assert lib.assertMsg (failures == []) "files devenv: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-files-devenv" {
      passthru = {inherit fixtureJson;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${python}/bin/python3 -I ${./devenv.py} ${fixture} ${pkgs.bash}/bin/bash
      ${pkgs.coreutils}/bin/printf 'PASS: files devenv\n' > "$out"
    '';
}
