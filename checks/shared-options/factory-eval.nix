# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai mkTest;
in {
  checks = {
    # ── sharedOptions tests ─────────────────────────────────────────
    factory-sharedOptions-empty-defaults = mkTest "sharedOptions-empty-defaults" (
      let
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            {config = {};}
          ];
        };
      in
        evaluated.config.ai.mcpServers
        == {}
        && evaluated.config.ai.rules == {}
        && evaluated.config.ai.settings.reasoningEffort == null
        && evaluated.config.ai.skills == {}
    );

    factory-sharedOptions-reasoning-effort-is-portable-intersection = mkTest "sharedOptions-reasoning-effort-is-portable-intersection" (
      let
        accepts = value:
          (builtins.tryEval
            (lib.evalModules {
              modules = [
                ai.sharedOptions
                {config.ai.settings.reasoningEffort = value;}
              ];
            }).config.ai.settings.reasoningEffort)
        .success;
      in
        accepts "low"
        && accepts "medium"
        && accepts "high"
        && accepts "xhigh"
        && !(accepts "max")
        && !(accepts "ultra")
    );

    factory-sharedOptions-accepts-mcpServer-entry = mkTest "sharedOptions-accepts-mcpServer-entry" (
      let
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            {
              config.ai.mcpServers.test = {
                type = "stdio";
                package = pkgs.hello;
                command = "hello";
              };
            }
          ];
        };
      in
        evaluated.config.ai.mcpServers.test.type == "stdio"
    );

    factory-generated-options-append-force-and-null = mkTest "generated-options-append-force-and-null" (
      let
        evaluate = module:
          (lib.evalModules {
            specialArgs = {inherit pkgs;};
            modules = [ai.sharedOptions module];
          }).config.ai.generated;
        appended = evaluate {ai.generated.check.json = "echo consumer";};
        forced = evaluate {ai.generated.check.json = lib.mkForce "echo only-consumer";};
        replaced = evaluate {ai.generated.formatter.json = "echo custom-formatter";};
        disabled = evaluate {
          ai.generated.formatter.markdown = null;
          ai.generated.guards.tableCells = false;
        };
        lazy =
          (lib.evalModules {
            specialArgs = {inherit pkgs;};
            modules = [
              ai.sharedOptions
              {ai.generated.check.yaml = lib.mkOverride lib.modules.defaultOverridePriority (throw "forced losing check");}
              {ai.generated.check.yaml = lib.mkForce "";}
            ];
          }).config.ai.generated;
      in
        lib.hasInfix "echo consumer" appended.check.json
        && lib.hasInfix ":" appended.check.json
        && forced.check.json == "echo only-consumer"
        && replaced.formatter.json == "echo custom-formatter"
        && disabled.formatter.markdown == null
        && !disabled.guards.tableCells
        && lazy.check.yaml == ""
    );

    factory-generated-treefmt-formatter-is-sandbox-correct = mkTest "generated-treefmt-formatter-is-sandbox-correct" (
      let
        config = {
          package = pkgs.writeShellScriptBin "treefmt-fixture" "exit 0";
          build.configFile = pkgs.writeText "treefmt-fixture.toml" "";
        };
      in
        ai.treefmtFormatter config
        == "${lib.getExe config.package} --config-file ${config.build.configFile} --tree-root . --walk filesystem --no-cache"
    );
  };
}
