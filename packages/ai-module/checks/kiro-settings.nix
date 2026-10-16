# Exercise the remaining Kiro surfaces and secret-provider edges on both backends.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  files = import ../lib/files/default.nix {inherit lib pkgs;};
  dagLib = import ./dag-lib.nix harness.hmLib;
  inherit (import ../../kiro-cli/checks/helpers.nix {inherit harness lib pkgs;}) renderedMcpJson;
  plainUrl = "https://example.invalid/mcp";
  servers = {
    empty = {};
    helper.demo = {
      type = "http";
      url.helper = "./failed-helper";
    };
    plain.demo = {
      type = "http";
      url = plainUrl;
    };
    private.demo = {
      type = "http";
      url.file = "credential-url";
    };
    secret.demo = {
      headers.X-Token.file = "header-token";
      type = "http";
      url.file = "credential-url";
    };
  };
  legacy = prefix:
    map (name: {
      codec = "dir";
      ledger = "materialize/kiro-${name}.manifest";
      path = "${prefix}/${name}";
    }) ["hooks" "settings" "steering"];
  fixture = lib.genAttrs ["devenv" "hm"] (backend: let
    evaluate =
      if backend == "hm"
      then harness.evalHmWithSpecialArgs {lib = dagLib;}
      else harness.evalDevenv;
    generate = name: let
      enabled = name != "disabled";
      serverKind =
        if builtins.hasAttr name servers
        then name
        else "empty";
      hookNames =
        if name == "plain"
        then ["alpha" "beta"]
        else lib.optional (name == "secret") "alpha";
      inherit
        (evaluate {
          ai = {
            activation2Order.secretNodes = ["fixture-provider"];
            kiro = {
              cli.enable = enabled;
              cli.native.settings = lib.optionalAttrs (lib.elem name ["helper" "plain" "private" "secret"]) {chat.enableTangentMode = true;};
              hooks = lib.genAttrs hookNames (command: {
                trigger = "Stop";
                action = {inherit command;};
              });
              hooksDir =
                if name == "directory"
                then ../../kiro-cli/checks/fixtures/kiro-hooks-dir
                else null;
              mcpServers = servers.${serverKind};
            };
          };
        })
        config
        ;
      plan = files.normalize {
        inherit backend;
        files = config.ai.files2;
        namespace = "ai";
        owners = config.ai.files2Owners;
      };
      expected =
        map (hook: ".kiro/hooks/${hook}.json") hookNames
        ++ lib.optional (name == "directory") ".kiro/hooks/sample.json"
        ++ lib.optionals (enabled && (backend == "hm" || lib.elem name ["helper" "plain" "private" "secret"])) [".kiro/settings/cli.json"]
        ++ lib.optionals (enabled && (backend == "hm" || serverKind != "empty")) [".kiro/settings/mcp.json"];
      graph =
        if backend == "hm"
        then config.home.activation
        else config.tasks;
      apply =
        graph.${
          if backend == "hm"
          then "ai2-files2-apply"
          else "ai2:files2-apply"
        };
      prune =
        graph.${
          if backend == "hm"
          then "ai2-files2-prune"
          else "ai2:files2-prune"
        };
      hasRun = lib.any (item: item.content ? run) plan;
    in
      assert config.ai.kiro.files == {} && config.ai.kiro.activation == {};
      assert config.ai.kiro.legacyLedgers == legacy ".kiro";
      assert lib.all (item: lib.elem item config.ai.legacyLedgers) (legacy ".kiro");
      assert builtins.attrNames config.ai.kiro.files2 == lib.sort builtins.lessThan expected;
      assert lib.all (item:
        item.method
        == "ro"
        && item.format == "json"
        && item.executable == null
        && item.mode
        == (
          if lib.hasSuffix "/mcp.json" item.path
          then
            (
              if lib.elem serverKind ["helper" "private" "secret"]
              then "0400"
              else "0444"
            )
          else null
        ))
      plan;
      assert lib.elem (
        if backend == "hm"
        then "checkLinkTargets"
        else "ai2:link-check"
      )
      prune.before;
      assert hasRun == lib.elem "fixture-provider" apply.after;
      assert backend != "hm" || hasRun == lib.elem "sops-nix" apply.after;
      assert lib.elem (
        if backend == "hm"
        then "linkGeneration"
        else "ai2:files-linked"
      )
      apply.after;
      assert lib.elem (
        if backend == "hm"
        then "ai2-files-ready"
        else "ai2:files-ready"
      )
      apply.before;
      assert lib.all (item: item.assertion) config.assertions; {
        inherit (config.ai.kiro) legacyLedgers;
        inherit plan;
        inputs =
          lib.mapAttrs (_: entry: {
            inherit (entry.content) source text;
          })
          config.ai.kiro._generatedFiles;
      };
    customDisabled = (evaluate {ai.kiro.configDir = ".custom";}).config;
  in
    assert customDisabled.ai.kiro.legacyLedgers == legacy ".custom";
    assert customDisabled.ai.kiro.files2 == {};
      lib.genAttrs ["directory" "disabled" "empty" "helper" "plain" "private" "secret"] generate);
  fixtureJson = builtins.toJSON {
    inherit fixture plainUrl;
    bash = lib.getExe pkgs.bash;
    templates =
      lib.mapAttrs (_: value: let
        text = renderedMcpJson value;
      in {
        inherit text;
        path = "${pkgs.writeText "kiro-mcp.json" text}";
      })
      servers;
  };
in {
  checks.ai-module-kiro-settings = pkgs.runCommandLocal "ai-module-kiro-settings" {passthru = {inherit fixtureJson;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./kiro-settings.py} \
      ${../lib/files}/engine.py ${pkgs.writeText "kiro-settings.json" fixtureJson} ${../../delegate-routing/eval/suite.py}
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
