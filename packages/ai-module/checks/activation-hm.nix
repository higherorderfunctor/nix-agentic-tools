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
        {ai.activation2 = definitions;}
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
          modules = [../modules/common.nix {ai.activation2 = definitions;}];
        }).config.ai.activation2;
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
        beforeNodes.hm = ["ai2-b"];
        command = "true";
      };
      b = {
        beforeNodes.hm = ["ai2-a"];
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
        afterNodes.hm = ["ai2-files-ready"];
        before = ["files"];
        command = "true";
      };
    };
    reserved = validate {
      a = {
        command = "true";
        name.hm = "ai2-ready";
      };
    };
    self = validate {
      a = {
        command = "true";
        afterNodes.hm = ["ai2-a"];
      };
    };
  };
  failures =
    lib.optional (builtins.attrNames graph != ["ai2-drain" "ai2-files-ready" "ai2-files2-prune" "ai2-ready" "ai2-write" "external-name"]) "gating"
    ++ lib.optional (graph.ai2-write.after != ["linkGeneration"] || graph.ai2-write.before != ["ai2-ready"]) "default edges"
    ++ lib.optional (graph.external-name.after != ["external-provider"] || graph.external-name.before != ["checkLinkTargets"]) "native edges"
    ++ lib.optional (graph.ai2-files-ready.after != ["linkGeneration"] || graph.ai2-files-ready.before != ["ai2-ready"]) "internal points"
    ++ lib.optional (config.ai.activation2Order.secretNodes != []) "secret default"
    ++ lib.optional (!lib.hasInfix "cycle" errors.cycle || !lib.hasInfix "ai2-a" errors.cycle || !lib.hasInfix "ai2-b" errors.cycle) "cycle"
    ++ lib.optional (!lib.hasInfix "cycle" errors.abstractCycle || !lib.hasInfix "ai2-a" errors.abstractCycle) "abstract cycle"
    ++ lib.optional (errors.duplicate != "ai.activation2: duplicate hm name shared") "duplicate"
    ++ lib.optional (errors.empty != "ai.activation2.a: command must be nonempty") "empty command"
    ++ lib.optional (!lib.hasInfix "invalid entry name" errors.invalid) "invalid name"
    ++ lib.optional (!lib.hasInfix "cycle" errors.nativeCycle || !lib.hasInfix "ai2-files-ready" errors.nativeCycle) "native cycle"
    ++ lib.optional (errors.reserved != "ai.activation2: reserved hm name ai2-ready") "reserved"
    ++ lib.optional (!lib.hasInfix "cycle ai2-a -> ai2-a" errors.self) "self edge";
  fixture = pkgs.writeText "activation-hm.json" (builtins.toJSON {
    drain = graph.ai2-drain.text;
    write = graph.ai2-write.text;
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
