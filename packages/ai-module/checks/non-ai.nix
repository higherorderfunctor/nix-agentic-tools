# Non-AI owners forward their commands through layer 1, then one backend graph.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # Spell out the native points; reusing pointNodes would pass if a point
  # were remapped in production and the consumer graph followed it.
  nativePoints = {
    devenv = {
      files = ["ai:files-linked"];
      materialized = ["ai:files-ready"];
      shell = ["devenv:enterShell"];
    };
    hm = {
      files = ["linkGeneration"];
      materialized = ["ai-files-ready"];
      secrets = ["sops-nix"];
      shell = ["ai-ready"];
    };
  };
  hmLib = import ./dag-lib.nix harness.hmLib;
  evaluate = backend:
    if backend == "hm"
    then harness.evalHmWithSpecialArgs {lib = hmLib;}
    else harness.evalDevenv;
  cases =
    [
      {
        backend = "devenv";
        config.services.beads = {
          enable = true;
          issuePrefix = "fixture";
          ledgerUrl = "file:///tmp/beads-ledger.git";
        };
        key = "beads-prepare";
        owner = "beads";
      }
      {
        backend = "devenv";
        config.git.settings.merge.conflictStyle = "zdiff3";
        key = "git-config";
        native = "git:config";
        owner = "git";
      }
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      {
        after = ["files" "secrets"];
        backend = "hm";
        config.glab = {
          enable = true;
          host.file = "/run/secrets/gitlab-url";
          keyringSync.enable = true;
          token.file = "/run/secrets/gitlab-token";
        };
        key = "glab-keyring-sync";
        owner = "glab";
      }
    ]
    ++ [
      {
        backend = "devenv";
        beforeNodes = ["git:config" "devenv:git-hooks:install"];
        config.git.branchless.enable = true;
        key = "git-branchless-init";
        modules = [
          {
            options.git-hooks.enable = lib.mkOption {
              default = true;
              type = lib.types.bool;
            };
          }
        ];
        owner = "git-branchless";
        suffix = "hooks";
      }
    ]
    ++ map (backend: {
      after = ["materialized"];
      inherit backend;
      config.ai.programs.semble.enable = true;
      key = "semble-cache-guard";
      owner = "semble";
    }) ["devenv" "hm"];
  check = case: let
    hm = case.backend == "hm";
    evaluated =
      if case ? modules
      then harness.evalDevenvModules (case.modules ++ [{inherit (case) config;}])
      else evaluate case.backend case.config;
    inherit (evaluated) config;
    entry = config.ai.${case.owner}.activation.${case.key};
    root = config.ai.activation.${case.key};
    native =
      case.native or (
        if hm
        then "ai-${case.key}"
        else "ai:${case.key}"
      );
    graph =
      if hm
      then config.home.activation
      else config.tasks;
    disabled = (evaluate case.backend {}).config;
    disabledGraph =
      if hm
      then disabled.home.activation
      else disabled.tasks;
    expectedAfter = case.after or ["files"];
    nodes = nativePoints.${case.backend};
  in
    harness.checkRows "${case.owner}/${case.backend} activation" ({
        "manual beads tasks do not enter the graph" =
          case.owner
          != "beads"
          || lib.all (task: !(task ? after) && !(task ? before)) (lib.attrValues (lib.filterAttrs (name: _: lib.hasPrefix "beads:" name) graph));
        "native task follows required predecessors" = graph.${native}.after == lib.concatMap (point: nodes.${point}) expectedAfter;
        "owner forwards the command and ordering without declaring files" =
          entry.command
          == root.command
          && root.enable
          && root.after == expectedAfter
          && root.beforeNodes.devenv == (case.beforeNodes or [])
          && config.ai.${case.owner}.files == {};
      }
      // lib.optionalAttrs (case.owner == "glab") {
        "disabled owner installs no task" = !(builtins.hasAttr native disabledGraph);
      }
      // lib.optionalAttrs (!(builtins.elem case.owner ["beads" "git" "git-branchless"])) {
        "native task precedes shell" = graph.${native}.before == nodes.shell;
      });
in {
  checks = builtins.listToAttrs (map (case: let
      name = "ai-module-${case.owner}-${case.backend}${lib.optionalString (case ? suffix) "-${case.suffix}"}";
    in {
      inherit name;
      value = harness.mkTest name (check case);
    })
    cases);
}
