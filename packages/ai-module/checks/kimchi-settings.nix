# Execute Kimchi settings generations and assert the backend provider edges.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  files = import ../lib/files/default.nix {inherit lib pkgs;};
  dagLib = import ./dag-lib.nix harness.hmLib;
  trust = {
    "/kimchi-fixture/link/project" = true;
    "/nonexistent/kimchi-project" = false;
  };
  fixture = lib.genAttrs ["devenv" "hm"] (backend:
    lib.genAttrs [".config/kimchi" "custom/kimchi"] (configDir: let
      isHm = backend == "hm";
      harnessDir =
        if isHm
        then "${configDir}/harness"
        else ".config/kimchi/harness";
      configPath =
        if isHm
        then "${configDir}/config.json"
        else ".kimchi/config.json";
      evaluate =
        if isHm
        then harness.evalHmWithSpecialArgs {lib = dagLib;}
        else harness.evalDevenv;
      generate = name: let
        enabled = name != "disabled";
        declared = lib.elem name ["helper" "plain" "run" "secret"];
        secret = isHm && lib.elem name ["helper" "secret"];
        inherit
          (evaluate {
            ai = {
              activationOrder.secretNodes = ["fixture-provider"];
              kimchi = {
                inherit configDir;
                enable = enabled;
                files = lib.optionalAttrs (!isHm && name == "run") {
                  ".kimchi/config.json".content = lib.mkForce {
                    run = ''
                      set -euETo pipefail
                      shopt -s inherit_errexit 2>/dev/null || :
                      exec ${pkgs.coreutils}/bin/cat "$DEVENV_ROOT/provider-data"
                    '';
                  };
                };
                gitTokens = lib.optionalAttrs secret {
                  "github.com" =
                    if name == "helper"
                    then redact.command "/run/redact-fixture/failed-helper"
                    else redact.file "/run/redact-fixture/git-token";
                };
                hooks = lib.optionalAttrs declared {TurnStart = [{hooks = [{command = "turn";}];}];};
                mcpServers = lib.optionalAttrs declared {
                  demo = {
                    type = "http";
                    url = "https://example.invalid/mcp";
                  };
                };
                native = {
                  harnessSettings = lib.optionalAttrs declared {hideThinkingBlock = true;};
                  settings = lib.optionalAttrs isHm {region = "us";} // lib.optionalAttrs declared {redaction.enabled = false;};
                };
                permissions = lib.optionalAttrs declared {defaultMode = "plan";};
                projectTrust = lib.optionalAttrs isHm trust;
              };
            };
          })
          config
          ;
        plan = files.normalize {
          inherit backend;
          files = config.ai.files;
          namespace = "ai";
          owners = config.ai.filesOwners;
        };
        copies = lib.filter (item: item.method != "symlink") plan;
        graph =
          if isHm
          then config.home.activation
          else config.tasks;
        applyName =
          if isHm
          then "ai-files-apply"
          else "ai:files-apply";
        apply = graph.${applyName};
        prune =
          graph.${
            if isHm
            then "ai-files-prune"
            else "ai:files-prune"
          };
        expected =
          if !enabled
          then []
          else if isHm
          then [
            "${configDir}/config.json"
            "${harnessDir}/mcp.json"
            "${harnessDir}/settings.json"
            "${harnessDir}/trust.json"
            ".config/kimchi/harness/permissions.json"
          ]
          else lib.optionals declared ["${harnessDir}/settings.json" ".kimchi/config.json" ".kimchi/hooks.json" ".kimchi/mcp.json" ".kimchi/permissions.json"];
        expectedLegacy =
          [
            {
              codec = "dir";
              ledger = "materialize/kimchi-agents-${builtins.hashString "sha256" (
                if isHm
                then configDir
                else ".kimchi/agents"
              )}.manifest";
              path =
                if isHm
                then "${harnessDir}/agents"
                else ".kimchi/agents";
            }
          ]
          ++ map (path: {
            codec = "dir";
            ledger = "materialize/kimchi-files-${builtins.hashString "sha256" path}.manifest";
            inherit path;
          })
          (lib.unique (
            if isHm
            then [configDir harnessDir ".config/kimchi/harness"]
            else [harnessDir ".kimchi"]
          ))
          ++ lib.optionals isHm (map (path: {
            codec = "json";
            ledger = "materialize/kimchi-shared-${builtins.hashString "sha256" path}.json";
            inherit path;
          }) [configPath "${harnessDir}/settings.json"]);
        hasRun = lib.any (item: item.content ? run) copies;
      in
        assert builtins.attrNames config.ai.kimchi.files == lib.sort builtins.lessThan expected;
        assert lib.all (path: config.ai.filesOwners.${path} == ["kimchi"]) expected;
        assert lib.all (item:
          item.format
          == "json"
          && item.executable == null
          && item.method
          == (
            if isHm && (item.path == "${harnessDir}/settings.json" || (item.path == configPath && !secret))
            then "rw"
            else "ro"
          )
          && item.mode
          == (
            if item.path == configPath && (!isHm || secret)
            then "0400"
            else null
          ))
        copies;
        assert lib.elem (
          if isHm
          then "checkLinkTargets"
          else "ai:link-check"
        )
        prune.before;
        assert (graph ? ${applyName}) == (plan != []);
        assert plan == [] || hasRun == lib.elem "fixture-provider" apply.after;
        assert plan == [] || !isHm || hasRun == lib.elem "sops-nix" apply.after;
        assert plan
        == []
        || lib.elem (
          if isHm
          then "linkGeneration"
          else "ai:files-linked"
        )
        apply.after;
        assert config.ai.kimchi.legacyLedgers == expectedLegacy;
        assert lib.all (item: lib.elem item config.ai.legacyLedgers) config.ai.kimchi.legacyLedgers;
        assert !enabled
        || isHm
        || !declared
        || (
          config.ai.files.".kimchi/hooks.json".method
          == "symlink"
          && config.ai.files.".kimchi/hooks.json".content.value
          == {
            hooks.TurnStart = [
              {
                hooks = [
                  {
                    command = "turn";
                    type = "command";
                  }
                ];
              }
            ];
          }
        );
        assert lib.all (item: item.assertion) config.assertions; {
          inherit configPath harnessDir;
          inherit (config.ai.kimchi) legacyLedgers;
          plan = copies;
          template = let
            value =
              if name == "plain"
              then config.ai.files.${configPath}.content.value
              else steps.plain.template.value;
          in {
            inherit value;
            path = "${pkgs.writeText "kimchi-config.json" (builtins.toJSON value)}";
          };
        };
      steps = lib.genAttrs ["disabled" "empty" "helper" "plain" "run" "secret"] generate;
    in
      assert lib.all (step: step.legacyLedgers == steps.disabled.legacyLedgers) (builtins.attrValues steps); steps));
  fixtureJson = builtins.toJSON {
    inherit fixture trust;
    bash = lib.getExe pkgs.bash;
    trustPath = "${pkgs.writeText "kimchi-project-trust.json" (builtins.toJSON trust)}";
  };
in {
  checks.ai-module-kimchi-settings = pkgs.runCommandLocal "ai-module-kimchi-settings" {passthru = {inherit fixtureJson;};} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./kimchi-settings.py} \
      ${../lib/files}/engine.py ${pkgs.writeText "kimchi-settings.json" fixtureJson}
    ${pkgs.coreutils}/bin/touch "$out"
  '';
}
