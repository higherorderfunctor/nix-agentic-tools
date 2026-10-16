{
  harness,
  lib,
  pkgs,
  ...
}: let
  activation = import ../lib/activation.nix {inherit lib;};
  dagLib = import ./dag-lib.nix lib;
  evaluate = definitions:
    (lib.evalModules {
      specialArgs = {
        lib = dagLib;
        inherit pkgs;
      };
      modules = [
        harness.hmStubs
        ../modules/homeManager/default.nix
        {ai.activation = definitions;}
      ];
    }).config;
  commands = {
    disabled = {
      command = ''${pkgs.coreutils}/bin/printf disabled > "$HOME/disabled"'';
      enable = false;
    };
    drain = {
      command = ''${pkgs.coreutils}/bin/printf drained > "$HOME/drain"'';
      enable = false;
      runWhenDisabled = true;
    };
    named = {
      after = [];
      afterNodes.hm = ["external-provider"];
      before = ["linkCheck"];
      command = ''${pkgs.coreutils}/bin/printf named > "$HOME/named"'';
      name.hm = "external-name";
    };
    write.command = ''${pkgs.coreutils}/bin/printf wrote > "$HOME/write"'';
  };
  config = evaluate commands;
  graph = config.home.activation;
  validate = definitions:
    activation.validate {
      backend = "hm";
      entries =
        (lib.evalModules {
          modules = [../modules/common.nix {ai.activation = definitions;}];
        }).config.ai.activation;
      secretNodes = ["sops-nix"];
    };
  errors = {
    abstractCycle = validate {
      a = {
        before = ["linkCheck"];
        command = "true";
      };
    };
    cycle = validate {
      a = {
        beforeNodes.hm = ["ai-b"];
        command = "true";
      };
      b = {
        beforeNodes.hm = ["ai-a"];
        command = "true";
      };
    };
    duplicate = validate {
      a = {
        command = "true";
        name.hm = "shared";
      };
      b = {
        command = "true";
        name.hm = "shared";
      };
    };
    empty = validate {a.command = "  \n";};
    invalid = validate {"bad/name".command = "true";};
    nativeCycle = validate {
      a = {
        afterNodes.hm = ["ai-files-ready"];
        before = ["files"];
        command = "true";
      };
    };
    reserved = validate {
      a = {
        command = "true";
        name.hm = "ai-ready";
      };
    };
    self = validate {
      a = {
        command = "true";
        afterNodes.hm = ["ai-a"];
      };
    };
  };
  failures =
    lib.optional (builtins.attrNames graph != ["ai-drain" "ai-files-prune" "ai-files-ready" "ai-ready" "ai-write" "external-name"]) "gating"
    ++ lib.optional (graph.ai-write.after != ["linkGeneration"] || graph.ai-write.before != ["ai-ready"]) "default edges"
    ++ lib.optional (graph.external-name.after != ["external-provider"] || graph.external-name.before != ["checkLinkTargets"]) "native edges"
    ++ lib.optional (graph.ai-files-ready.after != ["linkGeneration"] || graph.ai-files-ready.before != ["ai-ready"]) "internal points"
    ++ lib.optional (config.ai.activationOrder.secretNodes != []) "secret default"
    ++ lib.optional (!lib.hasInfix "cycle" errors.cycle || !lib.hasInfix "ai-a" errors.cycle || !lib.hasInfix "ai-b" errors.cycle) "cycle"
    ++ lib.optional (!lib.hasInfix "cycle" errors.abstractCycle || !lib.hasInfix "ai-a" errors.abstractCycle) "abstract cycle"
    ++ lib.optional (errors.duplicate != "ai.activation: duplicate hm name shared") "duplicate"
    ++ lib.optional (errors.empty != "ai.activation.a: command must be nonempty") "empty command"
    ++ lib.optional (!lib.hasInfix "invalid entry name" errors.invalid) "invalid name"
    ++ lib.optional (!lib.hasInfix "cycle" errors.nativeCycle || !lib.hasInfix "ai-files-ready" errors.nativeCycle) "native cycle"
    ++ lib.optional (errors.reserved != "ai.activation: reserved hm name ai-ready") "reserved"
    ++ lib.optional (!lib.hasInfix "cycle ai-a -> ai-a" errors.self) "self edge";
  fixture = pkgs.writeText "activation-hm.json" (builtins.toJSON {
    drain = graph.ai-drain.text;
    write = graph.ai-write.text;
  });
  shim = pkgs.writeText "activation-hm-run.sh" harness.hmRunShim;
in {
  checks.ai-module-activation-hm = assert lib.assertMsg (failures == []) "activation HM: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-activation-hm" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 -I ${./activation-hm.py} ${fixture} ${pkgs.bash}/bin/bash ${shim}
      ${pkgs.coreutils}/bin/printf 'PASS: activation HM\n' > "$out"
    '';
}
