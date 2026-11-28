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
  # Historical receipt identifiers for these directories and documents.
  # A new naming algorithm must still be able to discover the old receipts.
  receiptIds = {
    ".config/kimchi" = "035bd2b9569f8113a65c9e27c226078fa53df91fe844d4a655a90c46b442cd9e";
    ".config/kimchi/config.json" = "d2a1f6816b75f1d70a1825b9c4a9b5333efed6b058d44dff3568f06b4279f98d";
    ".config/kimchi/harness" = "973dbb6fca194c773a3b7d2cc3dfd092628eed472fd458e0305b2101412acaff";
    ".config/kimchi/harness/settings.json" = "e15b059f35df670ae8e8892ba5826fdbea2591df1a85f9cc0f1e4d0ab66509c2";
    ".kimchi" = "f687b7c79c400c5dbe15635b4c12bb39d98de8a018e5c5cfe955366c28e039b5";
    ".kimchi/agents" = "f51666134f0f7fab0992c2a9aad962375bdb543d9f51a613950f3f4797f3d149";
    "custom/kimchi" = "00c6a2dcb0a92cd96e2a8335a5d9aab36ce357305e8abda12653d696393b4eff";
    "custom/kimchi/config.json" = "19850c76e0ccd8338bf62a914a4831a55ef1755003497e4a178b49af87ca170a";
    "custom/kimchi/harness" = "a0e8830fb226624e3f5ce96d1384c325b0edbf383f6746a18fbbf6b4e59b209f";
    "custom/kimchi/harness/settings.json" = "a2dcb916dd0dfe8ee0985f5aa271cf03263c1de78f7edbec8b9327c389b38086";
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
                  settings = lib.optionalAttrs isHm {region = "us";} // lib.optionalAttrs declared {tui.wheelScrollLines = 3;};
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
              ledger = "materialize/kimchi-agents-${receiptIds.${
                if isHm
                then configDir
                else ".kimchi/agents"
              }}.manifest";
              path =
                if isHm
                then "${harnessDir}/agents"
                else ".kimchi/agents";
            }
          ]
          ++ map (path: {
            codec = "dir";
            ledger = "materialize/kimchi-files-${receiptIds.${path}}.manifest";
            inherit path;
          })
          (lib.unique (
            if isHm
            then [configDir harnessDir ".config/kimchi/harness"]
            else [harnessDir ".kimchi"]
          ))
          ++ lib.optionals isHm (map (path: {
            codec = "json";
            ledger = "materialize/kimchi-shared-${receiptIds.${path}}.json";
            inherit path;
          }) [configPath "${harnessDir}/settings.json"]);
        # Home Manager always renders trust; devenv renders only the provider fixture.
        hasRun = enabled && (isHm || name == "run");
        expectedCopies = lib.remove ".kimchi/hooks.json" expected;
      in
        assert builtins.attrNames config.ai.kimchi.files == lib.sort builtins.lessThan expected;
        assert lib.all (path: config.ai.claims.path.${path} == ["kimchi"]) expected;
        assert lib.sort builtins.lessThan (map (item: item.path) copies) == lib.sort builtins.lessThan expectedCopies;
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
        assert plan == [] || hasRun == lib.elem "fixture-provider" apply.after;
        assert plan == [] || !isHm || hasRun == lib.elem "sops-nix" apply.after;
        assert config.ai.kimchi.legacyLedgers == expectedLegacy;
        assert lib.all (item: lib.elem item config.ai.legacyLedgers) config.ai.kimchi.legacyLedgers;
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
      # The token renderer exists only in HM; the project renderer is devenv-only.
      steps = lib.genAttrs (["disabled" "empty" "plain"]
        ++ (
          if isHm
          then ["helper" "secret"]
          else ["run"]
        ))
      generate;
    in
      steps));
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
