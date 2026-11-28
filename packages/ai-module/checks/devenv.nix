{
  harness,
  inputs,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
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
  # Read the task boundary where native copy modes are checked. The same
  # native definition is accepted as a symlink before testing copy or seed.
  pruneBefore = method: copyMode:
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
      }).tasks."ai:files-prune".before;
  nativeOverrides = checkRows "devenv native file overrides" (builtins.listToAttrs (lib.concatMap (method:
    map (copyMode:
      lib.nameValuePair "${method} rejects native ${copyMode}" (rejectsChange (pruneBefore method) {
        valid = "symlink";
        invalid = copyMode;
        expected = ["ai:link-check"];
      })) ["copy" "seed"])
  ["ro" "rw" "symlink"]));
  python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
  # Every task an absent entry would have anchored must point past it.
  check = label: config: expectedFiles: emitted: {
    applyAfter ? null,
    linkCheckTo ? null,
    linkedFrom ? null,
  }: let
    inherit (config) tasks;
  in
    checkRows label ({
        "native links include neither copies nor spurious recursive leaves" = builtins.attrNames config.files == expectedFiles;
        "only tasks required by the plan are emitted" = builtins.filter (lib.hasPrefix "ai:files-") (builtins.attrNames tasks) == lib.sort builtins.lessThan (emitted ++ ["ai:files-inspect" "ai:files-linked" "ai:files-ready" "ai:files-snapshot"]);
      }
      // lib.optionalAttrs (applyAfter != null) {
        "apply waits only for existing dependencies" = tasks."ai:files-apply".after == applyAfter;
      }
      // lib.optionalAttrs (linkedFrom != null) {
        "files-linked waits for the right predecessor" = tasks."ai:files-linked".after == [linkedFrom];
      }
      // lib.optionalAttrs (linkCheckTo != null) {
        "link check skips absent guard and native entries" = tasks."ai:link-check".before == [linkCheckTo];
      });
  sinkRows = checkRows "devenv files" {
    "active copy and native links" = check "active copy and native links" active ["links/a.txt" "tree/b/c.md"] ["ai:files-apply" "ai:files-guard" "ai:files-prune"] {
      applyAfter = ["ai:files-linked" "vault:ready" "ai:files-guard" "ai:files-prune"];
      linkCheckTo = "ai:files-guard";
      linkedFrom = "devenv:files";
    };
    "copy-only plan" = check "copy-only plan" copyOnly [] ["ai:files-apply" "ai:files-prune"] {
      applyAfter = ["ai:files-linked" "ai:files-prune"];
      linkCheckTo = "ai:files-linked";
      linkedFrom = "ai:link-check";
    };
    "directory symlink is a native leaf rather than a traversed directory" = lib.mapAttrs (_: item: "${item.source}") (lib.filterAttrs (name: _: lib.hasPrefix "linked/link" name) linked.files) == {"linked/link" = "${linkedStore}/link";} && linked.files ? "linked/a/b/c.md";
    "empty plan" = check "empty plan" empty [] ["ai:files-prune"] {};
    "guard runs before both native linking and files-linked" = active.tasks."ai:files-guard".before == ["ai:files-linked" "devenv:files"];
    "unrelated native link without an AI file" = check "unrelated native link without an AI file" nativeOnly ["external"] ["ai:files-prune"] {
      linkCheckTo = "devenv:files";
      linkedFrom = "devenv:files";
    };
  };
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
  checks.ai-module-files-devenv = assert nativeOverrides;
  assert sinkRows;
    pkgs.runCommandLocal "ai-module-files-devenv" {
      passthru = {inherit fixtureJson;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${python}/bin/python3 -I ${./devenv.py} ${fixture} ${pkgs.bash}/bin/bash
      ${pkgs.coreutils}/bin/printf 'PASS: files devenv\n' > "$out"
    '';
}
