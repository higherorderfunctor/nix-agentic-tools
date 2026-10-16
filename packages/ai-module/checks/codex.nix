# Codex's complete staged map, command ordering, and disabled-first legacy drain.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm mkTest;
  files = import ../lib/files/default.nix {inherit lib pkgs;};
  dagLib = import ./dag-lib.nix harness.hmLib;
  fixture = lib.genAttrs ["devenv" "hm"] (backend:
    lib.genAttrs [".codex" "custom/codex"] (configDir: let
      isHm = backend == "hm";
      prefix =
        if isHm
        then configDir
        else ".codex";
      evaluate =
        if isHm
        then harness.evalHmWithSpecialArgs {lib = dagLib;}
        else harness.evalDevenv;
      generate = count: enable: let
        inherit
          ((evaluate {
            ai.codex = {
              inherit configDir enable;
              agents.reviewer = {
                description = "Review.";
                instructions.text = "Read first.";
              };
              context.text = "CONTEXT";
              execpolicyRules = lib.genAttrs (lib.take count ["alpha" "beta"]) (_: "POLICY\n");
              hooks.Stop = [{hooks = [{command = "validate";}];}];
              native.settings.model = "fixture";
              skills.probe = ./fixtures/probe-skill;
            };
          }))
          config
          ;
        plan = lib.filter (item: item.method != "symlink" && lib.hasPrefix "${prefix}/" item.path) (files.normalize {
          inherit backend;
          files = config.ai.files2;
          namespace = "ai";
          owners = config.ai.files2Owners;
        });
        expected =
          [".agents/skills/probe" "${prefix}/agents/reviewer.toml" "${prefix}/config.toml" "${prefix}/hooks.json"]
          ++ map (name: "${prefix}/rules/${name}.rules") (lib.take count ["alpha" "beta"])
          ++ lib.optionals isHm ["${prefix}/AGENTS.md" "${prefix}/app-server-daemon/settings.json"];
        graph =
          if isHm
          then config.home.activation
          else config.tasks;
        migrator = config.ai.codex.activation2.codex-migrate-skill-links or null;
        legacy =
          lib.optional isHm {
            codec = "dir";
            ledger = "materialize/codex-daemon-settings.manifest";
            path = "${prefix}/app-server-daemon";
          }
          ++ [
            {
              codec = "dir";
              ledger = "materialize/codex-execpolicy.manifest";
              path = "${prefix}/rules";
            }
          ];
      in
        assert config.ai.codex.files == {} && config.ai.codex.activation == {} && config.ai.codex._ownPlans == {};
        assert builtins.attrNames config.ai.codex._generatedFiles
        == (
          if enable
          then lib.sort builtins.lessThan expected
          else []
        );
        assert config.ai.codex.legacyLedgers == legacy;
        assert (evaluate {ai.codex = {inherit configDir;};}).config.ai.codex.legacyLedgers == legacy;
        assert lib.all (entry: lib.elem entry config.ai.legacyLedgers) legacy;
        assert !enable
        || lib.all (path:
          config.ai.files2Owners.${path}
          == ["codex"]
          && config.ai.files2.${path}.requires == ["${config.ai.codex._generatedTree}"]
          && config.ai.files2.${path}.mode == null
          && config.ai.files2.${path}.executable
          == (
            if lib.hasSuffix ".rules" path
            then false
            else null
          )
          && config.ai.files2.${path}.format
          == (
            if lib.hasSuffix ".toml" path
            then "toml"
            else if lib.hasSuffix ".json" path
            then "json"
            else if lib.hasSuffix ".md" path
            then "markdown"
            else "raw"
          )
          && config.ai.files2.${path}.method
          == (
            if lib.hasSuffix ".rules" path || lib.hasSuffix "settings.json" path
            then "ro"
            else "symlink"
          ))
        expected;
        assert enable || (config.ai.codex.files2 == {} && migrator == null);
        assert !enable || (migrator.after == [] && migrator.before == ["linkCheck"]);
        assert !enable
        || (
          if isHm
          then graph.ai2-codex-migrate-skill-links.before == ["checkLinkTargets"] && graph.ai2-codex-migrate-skill-links.after == []
          else graph."ai2:codex-migrate-skill-links".before == ["ai2:link-check"] && graph."ai2:codex-migrate-skill-links".after == ["devenv:files:cleanup"]
        );
        assert if isHm
        then
          config.ai.codex.activation2.codex-daemon-select.runWhenDisabled
          && graph ? ai2-codex-daemon-select
          && graph.ai2-codex-daemon-select.after == ["linkGeneration"]
        else !(config.ai.codex.activation2 ? codex-daemon-select);
        assert lib.all (entry: entry.assertion) config.assertions; {
          inherit legacy plan prefix;
          inputs = lib.mapAttrs (_: entry: {inherit (entry.content) text value;}) config.ai.codex._generatedFiles;
        };
    in
      map (step: generate step.count step.enable) [
        {
          count = 2;
          enable = true;
        }
        {
          count = 1;
          enable = true;
        }
        {
          count = 0;
          enable = true;
        }
        {
          count = 0;
          enable = false;
        }
      ]));
  # L038: an ordinary Codex path has one owner; a disabled competing owner
  # forwards nothing, whereas a disabled entry of a live owner still claims it.
  collision = enabled: entryEnabled: let
    evaluated = harness.evalHmModules [
      (import ../lib/runtime.nix {
        name = "probe";
        inherit enabled;
      })
      {
        ai.codex = {
          enable = true;
          files2."literal/codex".content.text = "Codex";
        };
        ai.probe.files2."literal/codex" = {
          enable = entryEnabled;
          content.text = lib.mkDefault "probe";
        };
      }
    ];
  in
    builtins.tryEval (builtins.deepSeq (files.normalize {
        backend = "hm";
        files = evaluated.config.ai.files2;
        namespace = "ai";
        owners = evaluated.config.ai.files2Owners;
      })
      true);
  fixtureJson = builtins.toJSON fixture;
in {
  checks = {
    ai-module-codex = assert lib.all (evaluate:
      !((evaluate {
        ai.codex.files2."literal/codex".content.text = "disabled";
      }).config.ai.files2 ? "literal/codex")) [evalHm evalDevenv];
    assert (collision false true).success;
    assert !(collision true true).success;
    assert !(collision true false).success;
      pkgs.runCommandLocal "ai-module-codex" {passthru = {inherit fixtureJson;};} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./codex.py} \
          ${../lib/files}/engine.py ${pkgs.writeText "codex-files.json" fixtureJson}
        ${pkgs.coreutils}/bin/touch "$out"
      '';
    ai-module-codex-context-lazy = mkTest "ai-module-codex-context-lazy" (
      lib.all (
        cell: let
          path =
            if cell.backend == "hm"
            then ".codex/AGENTS.md"
            else "AGENTS.md";
          evaluate =
            if cell.backend == "hm"
            then evalHm
            else evalDevenv;
          source = pkgs.runCommand "discarded-codex-context" {} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            exit 1
          '';
          override = lib.setAttrByPath (["ai"] ++ lib.optional cell.runtime "codex" ++ ["files2" path]) (
            if cell.disabled
            then {enable = false;}
            else {content.text = "replacement";}
          );
          inherit
            (evaluate (lib.recursiveUpdate {
                ai = {
                  codex.enable = true;
                  context = {inherit source;};
                };
              }
              override))
            config
            ;
          tree = config.ai.codex._generatedTree;
        in
          ((deliveredFiles config) ? ${path})
          == !cell.disabled
          && (cell.disabled || config.ai.files2.${path}.content.text == "replacement")
          && (tree == null || tree.drvPath != "")
      ) (lib.cartesianProduct {
        backend = ["devenv" "hm"];
        disabled = [false true];
        runtime = [false true];
      })
    );

    # Codex's share of the deleted normalized-keyed-pools-extend check.
    ai-module-codex-normalized-keyed-pools = mkTest "ai-module-codex-normalized-keyed-pools" (
      let
        samples = {
          agents = {
            description = "probe";
            instructions.text = "probe";
          };
          environmentVariables = "probe";
          mcpServers.command = "probe";
          skills = ./fixtures/probe-skill;
        };
      in
        lib.all (evaluate:
          lib.all (pool: let
            base.ai = {
              ${pool}.inherited = samples.${pool};
              codex = {
                enable = true;
                ${pool}.local = samples.${pool};
              };
            };
            original = (evaluate base).config.ai.codex.normalized.${pool};
            extension.extra = samples.${pool};
            result = value: (evaluate (lib.recursiveUpdate base {ai.codex.normalized.${pool} = value;})).config;
            extended = result extension;
            forced = result (lib.mkForce extension);
          in
            builtins.attrNames extended.ai.codex.normalized.${pool}
            == ["extra" "inherited" "local"]
            && extended.ai.codex.normalized.${pool}.inherited == original.inherited
            && builtins.attrNames forced.ai.codex.normalized.${pool} == ["extra"]
            && lib.all (assertion: assertion.assertion) (extended.assertions ++ forced.assertions))
          (builtins.attrNames samples)) [evalHm evalDevenv]
    );

    ai-module-codex-value-leaves = mkTest "ai-module-codex-value-leaves" (
      lib.all (evaluate: let
        evaluated = evaluate {
          ai.codex = {
            enable = true;
            files2.".codex/config.toml".content.value.ui.theme = "dark";
            native.settings = {
              model = "generated-model";
              model_reasoning_effort = "xhigh";
            };
          };
        };
        settings = evaluated.config.ai.files2.".codex/config.toml".content.value;
      in
        settings.ui.theme
        == "dark"
        && settings.model == "generated-model"
        && settings.model_reasoning_effort == "xhigh"
        && (deliveredFiles evaluated.config) ? ".codex/config.toml") [evalHm evalDevenv]
    );
  };
}
