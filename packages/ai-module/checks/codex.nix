# Codex's complete staged map, command ordering, and disabled-first legacy drain.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows deliveredFiles evalDevenv evalHm mkTest;
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
      generate = {
        enable,
        rules,
      }: let
        inherit
          ((evaluate {
            ai.codex = {
              inherit configDir enable;
              agents.reviewer = {
                description = "Review.";
                instructions.text = "Read first.";
              };
              context.text = "CONTEXT";
              execpolicyRules = lib.genAttrs rules (_: "POLICY\n");
              hooks.Stop = [{hooks = [{command = "validate";}];}];
              native.settings.model = "fixture";
              skills.probe = ./fixtures/probe-skill;
            };
          }))
          config
          ;
        plan = lib.filter (item: item.method != "symlink" && lib.hasPrefix "${prefix}/" item.path) (files.normalize {
          inherit backend;
          files = config.ai.files;
          namespace = "ai";
        });
        rulePaths = map (name: "${prefix}/rules/${name}.rules") rules;
        expected =
          [".agents/skills/probe" "${prefix}/agents/reviewer.toml" "${prefix}/config.toml" "${prefix}/hooks.json"]
          ++ rulePaths
          ++ lib.optionals isHm ["${prefix}/AGENTS.md" "${prefix}/app-server-daemon/settings.json"];
        graph =
          if isHm
          then config.home.activation
          else config.tasks;
        migrator = config.ai.codex.activation.codex-migrate-skill-links or null;
      in
        assert builtins.attrNames config.ai.codex._generatedFiles
        == (
          if enable
          then lib.sort builtins.lessThan expected
          else []
        );
        assert checkRows "Codex ${backend} ${configDir} (enabled=${lib.boolToString enable}, rules=${toString rules})" {
          "copy plan keeps rules and the Home Manager daemon settings" =
            map (item: item.path) plan
            == lib.optionals enable (lib.optional isHm "${prefix}/app-server-daemon/settings.json" ++ rulePaths);
        };
        assert config.ai.codex.legacyLedgers == legacy;
        assert !enable
        || lib.all (path:
          config.ai.claims.path.${path}
          == ["codex"]
          && config.ai.files.${path}.requires == ["${config.ai.codex._generatedTree}"]
          && config.ai.files.${path}.mode == null
          && config.ai.files.${path}.executable
          == (
            if lib.hasSuffix ".rules" path
            then false
            else null
          )
          && config.ai.files.${path}.format
          == (
            if lib.hasSuffix ".toml" path
            then "toml"
            else if lib.hasSuffix ".json" path
            then "json"
            else if lib.hasSuffix ".md" path
            then "markdown"
            else "raw"
          )
          && config.ai.files.${path}.method
          == (
            if lib.hasSuffix ".rules" path || lib.hasSuffix "settings.json" path
            then "ro"
            else "symlink"
          ))
        expected;
        assert enable || (config.ai.codex.files == {} && migrator == null);
        assert !enable
        || (
          if isHm
          then graph.ai-codex-migrate-skill-links.before == ["checkLinkTargets"] && graph.ai-codex-migrate-skill-links.after == []
          else graph."ai:codex-migrate-skill-links".before == ["ai:link-check"] && graph."ai:codex-migrate-skill-links".after == ["devenv:files:cleanup"]
        );
        assert if isHm
        then graph.ai-codex-daemon-select.after == ["linkGeneration"]
        else !(config.ai.codex.activation ? codex-daemon-select);
        assert lib.all (entry: entry.assertion) config.assertions; {
          inherit plan prefix;
          legacy = config.ai.codex.legacyLedgers;
        };
    in
      assert (evaluate {ai.codex = {inherit configDir;};}).config.ai.codex.legacyLedgers == legacy;
        map generate [
          {
            enable = true;
            rules = ["alpha" "beta"];
          }
          {
            enable = true;
            rules = ["alpha"];
          }
          {
            enable = true;
            rules = [];
          }
          {
            enable = false;
            rules = [];
          }
        ]));
  # An ordinary Codex path has one owner; a disabled competing owner
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
          files."literal/codex".content.text = "Codex";
        };
        ai.probe.files."literal/codex" = {
          enable = entryEnabled;
          content.text = lib.mkDefault "probe";
        };
      }
    ];
  in
    map (item: item.message) (builtins.filter (item: !item.assertion) evaluated.config.assertions);
  fixtureJson = builtins.toJSON fixture;
in {
  checks = {
    ai-module-codex = assert lib.all (evaluate:
      !((evaluate {
        ai.codex.files."literal/codex".content.text = "disabled";
      }).config.ai.files ? "literal/codex")) [evalHm evalDevenv];
    assert collision false true == [];
    assert collision true false == ["ai.claims.path.literal/codex: claimed by codex and probe"];
      pkgs.runCommandLocal "ai-module-codex" {passthru = {inherit fixtureJson;};} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./codex.py} \
          ${../lib/files}/engine.py ${pkgs.writeText "codex-files.json" fixtureJson}
        ${pkgs.coreutils}/bin/touch "$out"
      '';
    # Evaluating a derivation cannot reveal that an overridden source would
    # still be built. Realize each replacement tree to detect that dependency.
    ai-module-codex-context-lazy = let
      cases =
        map (
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
            override = lib.setAttrByPath (["ai"] ++ lib.optional cell.runtime "codex" ++ ["files" path]) (
              if cell.disabled
              then {enable = false;}
              else {content.text = "replacement";}
            );
            inherit
              (evaluate (lib.recursiveUpdate {
                  ai = {
                    codex = {
                      enable = true;
                      # Keep a tree even if the context is suppressed.
                      native.settings.model = "fixture";
                    };
                    context = {inherit source;};
                  };
                }
                override))
              config
              ;
            tree = config.ai.codex._generatedTree;
          in
            assert checkRows "Codex discarded context ${cell.backend} (disabled=${lib.boolToString cell.disabled}, runtime=${lib.boolToString cell.runtime})" (
              lib.optionalAttrs (!(cell.runtime && cell.disabled)) {
                "disabled context is not delivered" = ((deliveredFiles config) ? ${path}) == !cell.disabled;
              }
              // {
                "text override does not fall back to the discarded source" = cell.disabled || config.ai.files.${path}.content.text == "replacement";
              }
            ); tree
        ) (lib.cartesianProduct {
          backend = ["devenv" "hm"];
          disabled = [false true];
          runtime = [false true];
        });
    in
      pkgs.runCommand "ai-module-codex-context-lazy" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.concatMapStringsSep "\n" (tree: "test -d ${tree}") cases}
        printf 'PASS: discarded context is not a dependency of the generated tree\n' > "$out"
      '';

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
            files.".codex/config.toml".content.value.ui.theme = "dark";
            native.settings = {
              model = "generated-model";
              model_reasoning_effort = "xhigh";
            };
          };
        };
        settings = evaluated.config.ai.files.".codex/config.toml".content.value;
      in
        settings.ui.theme
        == "dark"
        && settings.model == "generated-model"
        && settings.model_reasoning_effort == "xhigh"
        && (deliveredFiles evaluated.config) ? ".codex/config.toml") [evalHm evalDevenv]
    );
  };
}
