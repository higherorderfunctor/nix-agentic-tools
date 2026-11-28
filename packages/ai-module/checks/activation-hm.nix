{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows;
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
  graphRows = checkRows "Home Manager activation graph" {
    "default writer cannot run before links or after readiness" = graph.ai-write.after == ["linkGeneration"] && graph.ai-write.before == ["ai-ready"];
    "files-ready cannot run before links or after activation readiness" = graph.ai-files-ready.after == ["linkGeneration"] && graph.ai-files-ready.before == ["ai-ready"];
    "named writer retains explicit external and pre-link dependencies" = graph.external-name.after == ["external-provider"] && graph.external-name.before == ["checkLinkTargets"];
    "only the disabled entry with drain enabled survives" = builtins.attrNames graph == ["ai-drain" "ai-files-prune" "ai-files-ready" "ai-ready" "ai-write" "external-name"];
    "provider nodes are not declared by default" = config.ai.activationOrder.secretNodes == [];
  };
  validationRows = checkRows "Home Manager activation validation" {
    "blank command cannot become a no-op activation" = errors.empty == "ai.activation.a: command must be nonempty";
    "commands with the same native name cannot overwrite each other" = errors.duplicate == "ai.activation: duplicate hm name shared";
    "entry key cannot contain a slash" = errors.invalid == ''ai.activation: invalid entry name "bad/name"'';
    "explicit edges cannot form a loop between two owners" = lib.hasInfix "cycle" errors.cycle && lib.hasInfix "ai-a" errors.cycle && lib.hasInfix "ai-b" errors.cycle;
    "native edge cannot loop through files-ready" = lib.hasInfix "cycle" errors.nativeCycle && lib.hasInfix "ai-files-ready" errors.nativeCycle;
    "ordinary entry cannot shadow internal readiness" = errors.reserved == "ai.activation: reserved hm name ai-ready";
    "point edges cannot schedule a default writer before link check" = lib.hasInfix "cycle" errors.abstractCycle && lib.hasInfix "ai-a" errors.abstractCycle && lib.hasInfix "checkLinkTargets" errors.abstractCycle;
    "self dependency cannot bypass cycle detection" = errors.self == "ai.activation: cycle ai-a -> ai-a";
  };
  fixture = pkgs.writeText "activation-hm.json" (builtins.toJSON {
    drain = graph.ai-drain.text;
    write = graph.ai-write.text;
  });
  shim = pkgs.writeText "activation-hm-run.sh" harness.hmRunShim;
in {
  checks.ai-module-activation-hm = assert graphRows;
  assert validationRows;
    pkgs.runCommandLocal "ai-module-activation-hm" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 -I ${./activation-hm.py} ${fixture} ${pkgs.bash}/bin/bash ${shim}
      ${pkgs.coreutils}/bin/printf 'PASS: activation HM\n' > "$out"
    '';
}
