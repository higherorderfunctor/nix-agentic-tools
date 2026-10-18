# Non-AI owners forward their commands through layer 1, then one backend graph.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
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
        linuxOnly = true;
        owner = "glab";
      }
      {
        after = ["files" "secrets"];
        backend = "hm";
        config.services.mcp-servers.servers.github-mcp = {
          enable = true;
          settings.credentials = redact.file "/run/secrets/gh-token";
        };
        key = "mcp-restart-on-secret-rotation";
        linuxOnly = true;
        owner = "mcp-services";
      }
    ]
    ++ map (hooks: {
      backend = "devenv";
      beforeNodes = ["git:config"] ++ lib.optional hooks "devenv:git-hooks:install";
      config.git.branchless.enable = true;
      key = "git-branchless-init";
      modules = [
        {
          options.git-hooks.enable = lib.mkOption {
            default = hooks;
            type = lib.types.bool;
          };
        }
      ];
      owner = "git-branchless";
      suffix =
        if hooks
        then "hooks"
        else "no-hooks";
    }) [false true]
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
    nodesFor = (import ../lib/activation.nix {inherit lib;}).pointNodes case.backend (
      if hm
      then ["sops-nix"]
      else []
    );
  in
    entry.command
    == root.command
    && root.enable
    && root.after == expectedAfter
    && root.beforeNodes.devenv == (case.beforeNodes or [])
    && graph.${native}.after == lib.concatMap nodesFor expectedAfter
    && graph.${native}.before == lib.concatMap nodesFor ["shell"] ++ (case.beforeNodes or [])
    && config.ai.${case.owner}.files == {}
    && (case.owner == "git" || !(builtins.hasAttr native disabledGraph))
    && (case.owner != "beads" || lib.all (task: !(task ? after) && !(task ? before)) (lib.attrValues (lib.filterAttrs (name: _: lib.hasPrefix "beads:" name) graph)));
in {
  checks = builtins.listToAttrs (map (case: let
      name = "ai-module-${case.owner}-${case.backend}${lib.optionalString (case ? suffix) "-${case.suffix}"}";
    in {
      inherit name;
      value = harness.mkTest name (check case);
    })
    (lib.filter (case: !(case.linuxOnly or false) || pkgs.stdenv.hostPlatform.isLinux) cases));
}
