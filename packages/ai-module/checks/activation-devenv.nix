{
  harness,
  lib,
  pkgs,
  ...
}: let
  activation = import ../lib/activation.nix {inherit lib;};
  entries = hasNative: {
    apply = {
      after = ["files" "secrets"];
      afterNodes.devenv = ["ai:guard" "ai:prune"];
      before = ["materialized"];
      command = ''${pkgs.coreutils}/bin/printf applied > "$DEVENV_ROOT/applied"'';
    };
    beforeCleanup = {
      after = [];
      before = ["linkCheck"];
      beforeNodes.devenv = ["devenv:files:cleanup"];
      command = ''${pkgs.coreutils}/bin/true'';
    };
    disabled = {
      command = ''${pkgs.coreutils}/bin/printf disabled > "$DEVENV_ROOT/disabled"'';
      enable = false;
    };
    failure.command = ''
      ${pkgs.coreutils}/bin/printf started > "$DEVENV_ROOT/failure-started"
      ${pkgs.coreutils}/bin/false
      ${pkgs.coreutils}/bin/printf escaped > "$DEVENV_ROOT/failure-escaped"
    '';
    guard = {
      after = ["linkCheck"];
      before = ["files"];
      beforeNodes.devenv = lib.optional hasNative "devenv:files";
      command = ''${pkgs.coreutils}/bin/true'';
    };
    preLink = {
      after = [];
      before = ["linkCheck"];
      command = ''${pkgs.coreutils}/bin/true'';
    };
    prune = {
      after = [];
      before = ["linkCheck"];
      command = ''${pkgs.coreutils}/bin/printf pruned > "$DEVENV_ROOT/pruned"'';
      enable = false;
      runWhenDisabled = true;
    };
    success = {
      command = ''${pkgs.coreutils}/bin/printf success > "$DEVENV_ROOT/success"'';
      name.devenv = "external:success";
    };
  };
  evaluate = hasNative:
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        harness.devenvStubs
        ../modules/devenv/default.nix
        {ai.activation = entries hasNative;}
        (lib.optionalAttrs hasNative {files.native.source = ../docs/DESIGN.md;})
      ];
    }).config;
  cases = map (hasNative: {
    inherit hasNative;
    config = evaluate hasNative;
  }) [false true];
  check = {
    config,
    hasNative,
  }: let
    # No files link emits no guard, so link-check reaches the next anchor.
    linkedFrom =
      if hasNative
      then "devenv:files"
      else "ai:link-check";
    linkTo =
      if hasNative
      then "devenv:files"
      else "ai:files-linked";
    inherit (config) tasks;
  in
    lib.optional (config.ai.activationOrder.secretNodes != []) "default secret nodes"
    ++ lib.optional (tasks."ai:link-check".after != ["devenv:files:cleanup"] || tasks."ai:link-check".before != [linkTo]) "link check"
    ++ lib.optional (tasks."ai:files-linked".after != [linkedFrom] || tasks."ai:files-linked".before != ["ai:files-ready"]) "files linked"
    ++ lib.optional (tasks."ai:files-ready".after != ["ai:files-linked"] || tasks."ai:files-ready".before != ["devenv:enterShell"]) "files ready"
    ++ lib.optional (tasks."ai:guard".after != ["ai:link-check"] || tasks."ai:guard".before != ["ai:files-linked"] ++ lib.optional hasNative "devenv:files") "guard edges"
    ++ lib.optional (tasks."ai:prune".after != ["devenv:files:cleanup"] || tasks."ai:prune".before != ["ai:link-check"]) "prune drain"
    ++ lib.optional (tasks."ai:preLink".after != ["devenv:files:cleanup"] || tasks."ai:preLink".before != ["ai:link-check"]) "pre-link cleanup"
    ++ lib.optional (tasks."ai:beforeCleanup".after != [] || tasks."ai:beforeCleanup".before != ["ai:link-check" "devenv:files:cleanup"]) "before-cleanup exception"
    ++ lib.optional (tasks."ai:apply".after != ["ai:files-linked" "ai:guard" "ai:prune"] || tasks."ai:apply".before != ["ai:files-ready"]) "apply edges"
    ++ lib.optional (builtins.hasAttr "ai:disabled" tasks || !(builtins.hasAttr "external:success" tasks)) "enable and name"
    ++ lib.optional (!hasNative && lib.any (task: lib.elem "devenv:files" (task.after ++ task.before)) (builtins.attrValues tasks)) "missing native task edge";
  provider = evaluate false;
  withProvider =
    (lib.evalModules {
      specialArgs = {inherit pkgs;};
      modules = [
        harness.devenvStubs
        ../modules/devenv/default.nix
        {ai.activationOrder.secretNodes = ["vault:ready"];}
        {ai.activation = entries false;}
      ];
    }).config.tasks;
  validate = definitions:
    activation.validate {
      backend = "devenv";
      entries =
        (lib.evalModules {
          modules = [../modules/common.nix {ai.activation = definitions;}];
        }).config.ai.activation;
      nativeFiles = false;
      secretNodes = [];
    };
  invalidName = validate {
    named = {
      command = "true";
      name.devenv = "external-success";
    };
  };
  cleanupCycle = validate {
    a = {
      after = [];
      before = ["linkCheck"];
      beforeNodes.devenv = ["ai:x"];
      command = "true";
    };
    x = {
      after = [];
      before = [];
      beforeNodes.devenv = ["devenv:files:cleanup"];
      command = "true";
    };
  };
  failures =
    lib.concatMap check cases
    ++ lib.optional (invalidName != ''ai.activation.named: invalid devenv name "external-success"'') "invalid devenv name"
    ++ lib.optional (!lib.hasInfix "cycle" cleanupCycle || !lib.hasInfix "devenv:files:cleanup" cleanupCycle) "cleanup cycle"
    ++ lib.optional (withProvider."ai:apply".after != ["ai:files-linked" "vault:ready" "ai:guard" "ai:prune"]) "provider edge";
  fixtureJson = builtins.toJSON {
    failure = provider.tasks."ai:failure".exec;
    prune = provider.tasks."ai:prune".exec;
    success = provider.tasks."external:success".exec;
  };
  fixture = pkgs.writeText "activation-devenv.json" fixtureJson;
in {
  checks.ai-module-activation-devenv = assert lib.assertMsg (failures == []) "activation devenv: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-activation-devenv" {
      passthru = {inherit fixtureJson;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 -I ${./activation-devenv.py} ${fixture} ${pkgs.bash}/bin/bash
      ${pkgs.coreutils}/bin/printf 'PASS: activation devenv\n' > "$out"
    '';
}
