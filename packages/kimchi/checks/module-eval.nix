# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest mkWrapperGrepTest;
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
in {
  checks = {
    module-kimchi-config-root-validation = mkTest "kimchi-config-root-validation" (
      let
        accepts = eval: configDir:
          (builtins.tryEval (builtins.deepSeq
            (eval {
              ai.kimchi = {
                enable = true;
                inherit configDir;
              };
            }).config.ai.kimchi.configDir
            true)).success;
      in
        lib.all (eval: accepts eval ".config/kimchi" && !(accepts eval ".custom-kimchi")) [evalHm evalDevenv]
    );

    module-kimchi-agents-directory = mkTest "kimchi-agents-directory" (
      let
        config.ai.kimchi = {
          enable = true;
          agentsDir = ../../claude-code/checks/fixtures/claude-agents;
        };
        expected = builtins.readFile ../../claude-code/checks/fixtures/claude-agents/agent-one.md;
        hm = (evalHm config).config.home.file;
        devenv = (evalDevenv config).config.files;
      in
        hm.".config/kimchi/harness/agents/agent-one.md".source
        == devenv.".kimchi/agents/agent-one.md".source
        && builtins.readFile devenv.".kimchi/agents/agent-one.md".source == expected
        && hm ? ".config/kimchi/harness/agents/agent-two.md"
        && devenv ? ".kimchi/agents/agent-two.md"
    );

    module-kimchi-explicit-env-precedence = let
      config.ai.kimchi = {
        enable = true;
        telemetry = false;
        environmentVariables = {
          KIMCHI_NO_UPDATE_CHECK = "0";
          KIMCHI_TELEMETRY_ENABLED = "1";
        };
      };
      packages = {
        hm = builtins.head (evalHm config).config.home.packages;
        devenv = builtins.head (evalDevenv config).config.packages;
      };
    in
      pkgs.linkFarm "kimchi-explicit-env-precedence" (lib.mapAttrsToList (backend: package: {
          name = backend;
          path = mkWrapperGrepTest {
            name = "kimchi-explicit-env-precedence-${backend}";
            inherit package;
            bin = "kimchi";
            needles = ["export KIMCHI_NO_UPDATE_CHECK='0'" "export KIMCHI_TELEMETRY_ENABLED='1'"];
            absentNeedles = ["export KIMCHI_NO_UPDATE_CHECK='1'" "export KIMCHI_TELEMETRY_ENABLED='0'"];
          };
        })
        packages);

    module-kimchi-context-filename-validation = mkTest "kimchi-context-filename-validation" (
      let
        accepts = eval: filename:
          lib.all (entry: entry.assertion)
          (eval {
            ai.kimchi = {
              enable = true;
              context = {
                inherit filename;
                text = "Guidance.";
              };
            };
          }).config.assertions;
      in
        lib.all (eval: accepts eval "AGENTS.md" && !(accepts eval "CUSTOM.md")) [evalHm evalDevenv]
    );

    module-kimchi-skill-path-inheritance = mkTest "kimchi-skill-path-inheritance" (
      let
        defaults.ai.kimchi.enable = true;
        explicit = paths: {
          ai.kimchi = {
            enable = true;
            nativeSettings.skillPaths = paths;
          };
        };
        projectPaths = paths:
          (builtins.fromJSON (evalDevenv (explicit paths)).config.files.".kimchi/config.json".text).skillPaths;
      in
        !((evalDevenv defaults).config.files ? ".kimchi/config.json")
        && !((evalHm defaults).config.home.activation ? kimchiConfigMerge)
        && projectPaths [] == []
        && projectPaths [".custom/skills"] == [".custom/skills"]
        && (evalHm (explicit [])).config.home.activation ? kimchiConfigMerge
    );

    module-kimchi-skill-source-identity = mkTest "kimchi-skill-source-identity" (
      let
        skill = ./fixtures/store-skill;
        skills.example = skill;
        directories = helpers.mkSkillDirectoryEntries ".agents" skills;
        leaves = helpers.mkDevenvSkillEntries ".kimchi" skills;
        packageLeaves = helpers.mkDevenvSkillEntries ".claude" {example = "${skill}";};
        root = "${directories.".agents/skills/example".source}";
      in
        toString leaves.".kimchi/skills/example/SKILL.md".source
        == "${root}/SKILL.md"
        && toString leaves.".kimchi/skills/example/references/context.txt".source == "${root}/references/context.txt"
        && toString packageLeaves.".claude/skills/example/SKILL.md".source == "${root}/SKILL.md"
        && "${skill + "/SKILL.md"}" != "${root}/SKILL.md"
    );

    # `supportedPools` now owns every normalized per-runtime option gate, not
    # shell alone. Each failure has an identical supported-runtime control so an
    # unrelated eval failure cannot make the exclusion look correct.
    module-kimchi-context-composes-root-first = mkTest "kimchi-context-composes-root-first" (
      let
        config.ai = {
          context.text = "Shared context.";
          kimchi = {
            context.text = "Kimchi context.";
            enable = true;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = "Shared context.\n\nKimchi context.";
      in
        hm.config.home.file.".config/kimchi/harness/AGENTS.md".text
        == expected
        && devenv.config.files."AGENTS.md".text == expected
    );
    module-kimchi-layered-rules-and-agents = mkTest "kimchi-layered-rules-and-agents" (
      let
        config.ai = {
          context.text = "Shared context.";
          rules = {
            dropped.text = "DROP-RULE";
            replaced.text = "ROOT-RULE";
            scoped = {
              matcher = ["src/**"];
              text = "SCOPED-RULE";
            };
          };
          agents = {
            dropped = {
              description = "DROP-AGENT";
              instructions = "DROP-BODY";
            };
            replaced = {
              description = "ROOT-AGENT";
              instructions = "ROOT-BODY";
            };
            inherited = {
              description = "INHERITED-AGENT";
              instructions = "INHERITED-BODY";
            };
          };
          kimchi = {
            enable = true;
            rules = {
              dropped = null;
              replaced.text = "KIMCHI-RULE";
            };
            agents = {
              dropped = null;
              replaced = {
                description = "KIMCHI-AGENT";
                instructions = "KIMCHI-BODY";
              };
            };
          };
        };
        hm = (evalHm config).config.home.file;
        devenv = (evalDevenv config).config.files;
        guidance = devenv."AGENTS.md".text;
      in
        hm.".config/kimchi/harness/AGENTS.md".text
        == guidance
        && lib.hasPrefix "Shared context." guidance
        && lib.hasInfix "files matching: `src/**`" guidance
        && lib.hasInfix "KIMCHI-RULE" guidance
        && !(lib.hasInfix "ROOT-RULE" guidance)
        && !(lib.hasInfix "DROP-RULE" guidance)
        && hm.".config/kimchi/harness/agents/replaced.md".text == devenv.".kimchi/agents/replaced.md".text
        && lib.hasInfix "KIMCHI-BODY" devenv.".kimchi/agents/replaced.md".text
        && devenv ? ".kimchi/agents/inherited.md"
        && !(devenv ? ".kimchi/agents/dropped.md")
    );

    module-kimchi-project-mcp-layering = mkTest "kimchi-project-mcp-layering" (
      let
        config.ai = {
          mcpServers = {
            inherited = {command = "inherited-server";};
            replaced = {
              command = "root-server";
              args = ["root-only"];
            };
            dropped = {command = "dropped-server";};
          };
          kimchi = {
            enable = true;
            mcpServers = {
              dropped = null;
              replaced.command = "kimchi-server";
            };
          };
        };
        hm = (evalHm config).config.home.file;
        devenv = (evalDevenv config).config.files;
        servers = (builtins.fromJSON devenv.".kimchi/mcp.json".text).mcpServers;
      in
        hm.".config/kimchi/harness/mcp.json".text
        == devenv.".kimchi/mcp.json".text
        && servers ? inherited
        && !(servers ? dropped)
        && servers.replaced.command == "kimchi-server"
        && !(lib.hasInfix "root-only" devenv.".kimchi/mcp.json".text)
        && !(devenv ? ".config/kimchi/harness/mcp.json")
    );

    module-kimchi-final-file-overrides = mkTest "kimchi-final-file-overrides" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            context.text = "Generated guidance.";
            agents.example = {
              description = "Example";
              instructions = "Generated agent.";
            };
            mcpServers.example.command = "example-server";
            nativeSettings.llmEndpoint = "https://generated.example.test";
            harnessSettings.defaultThinkingLevel = "medium";
            files = {
              "AGENTS.md".text = "Replaced guidance.";
              ".kimchi/agents/example.md" = null;
              ".kimchi/mcp.json".text = "{}";
              ".kimchi/config.json".text = ''{"llmEndpoint":"https://replacement.example.test"}'';
              ".config/kimchi/harness/settings.json" = null;
            };
          };
        };
        files = result.config.files;
      in
        files."AGENTS.md".text
        == "Replaced guidance."
        && files.".kimchi/mcp.json".text == "{}"
        && !(files ? ".kimchi/agents/example.md")
        && (builtins.fromJSON files.".kimchi/config.json".text).llmEndpoint == "https://replacement.example.test"
        && !(files ? ".config/kimchi/harness/settings.json")
    );

    module-kimchi-semantic-tool-boundary = mkTest "kimchi-semantic-tool-boundary" (
      let
        accepts = eval: tools:
          lib.all (entry: entry.assertion)
          (eval {
            ai.kimchi = {
              enable = true;
              agents.example = {
                description = "Example";
                instructions = "Read the source.";
                inherit tools;
              };
            };
          }).config.assertions;
      in
        lib.all (eval: accepts eval null && accepts eval [] && !(accepts eval ["Read"])) [evalHm evalDevenv]
    );

    module-kimchi-native-telemetry-scope = mkTest "kimchi-native-telemetry-scope" (
      let
        config.ai.kimchi = {
          enable = true;
          nativeSettings.telemetry.endpoint = "https://telemetry.example.test";
        };
        valid = result: lib.all (entry: entry.assertion) result.config.assertions;
      in
        valid (evalHm config) && !(valid (evalDevenv config))
    );

    module-kimchi-role-model-validation = mkTest "kimchi-role-model-validation" (
      let
        accepts = value:
          (builtins.tryEval (builtins.deepSeq
            (evalHm {
              ai.kimchi = {
                enable = true;
                harnessSettings.modelRoles.builder = value;
              };
            }).config.ai.kimchi.harnessSettings
            true)).success;
      in
        accepts "provider/model"
        && accepts ["provider/model"]
        && !(accepts "")
        && !(accepts "  ")
        && !(accepts [])
        && !(accepts [""])
    );

    module-kimchi-role-name-validation = mkTest "kimchi-role-name-validation" (
      let
        accepts = role:
          lib.all (entry: entry.assertion)
          (evalHm {
            ai.kimchi = {
              enable = true;
              harnessSettings.modelRoles.${role} = "provider/model";
            };
          }).config.assertions;
      in
        accepts "builder" && !(accepts "unknown")
    );

    module-kimchi-global-only-settings-explicit = mkTest "kimchi-global-only-settings-explicit" (
      let
        config.ai.kimchi = {
          enable = true;
          harnessSettings.modelRoles.orchestrator = "provider/model";
        };
        valid = result: lib.all (entry: entry.assertion) result.config.assertions;
      in
        valid (evalHm config) && !(valid (evalDevenv config))
    );

    # ── Kimchi (mkAiApp factory participant) ──────────────────────────
    module-kimchi-default-disabled = mkTest "kimchi-default-disabled" (!(evalHm {}).config.ai.kimchi.enable);

    module-kimchi-enable-toggles = mkTest "kimchi-enable-toggles" (evalHm {ai.kimchi.enable = true;}).config.ai.kimchi.enable;

    # Regression lock for the flattenDotKeys bug: config.json must be NESTED
    # JSON, never Kiro-style flat dot keys ("telemetry.enabled").
    module-kimchi-config-json-nested = mkTest "kimchi-config-json-nested" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            nativeSettings.mcpSearch.fieldWeights.name = 2;
          };
        };
        text = result.config.files.".kimchi/config.json".text;
      in
        lib.hasInfix ''"mcpSearch":{"fieldWeights":{"name":2}}'' text
        && !lib.hasInfix "fieldWeights.name" text
    );

    # Parity: the same config.json surface triggers the HM activation merge.
    module-kimchi-config-json-hm-merge = mkTest "kimchi-config-json-hm-merge" (
      let
        result = evalHm {
          ai.kimchi = {
            enable = true;
            nativeSettings.telemetry.enabled = false;
          };
        };
      in
        result.config.home.activation ? kimchiConfigMerge
    );

    # harnessSettings render to harness/settings.json (mutable-state tree).
    module-kimchi-harness-settings = mkTest "kimchi-harness-settings" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            harnessSettings.defaultThinkingLevel = "medium";
          };
        };
      in
        result.config.files ? ".config/kimchi/harness/settings.json"
    );

    # The Cast AI key is a runtime credential ({file|helper}); setting
    # apiKey.file must evaluate and must never become a static env var.
    module-kimchi-credential = mkTest "kimchi-credential" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            apiKey.file = "/run/secrets/kimchi-key";
          };
        };
      in
        builtins.length result.config.packages
        == 1
        # The cross-harness SSH default is exercised separately; this assertion
        # guards only against baking the Kimchi credential into the environment.
        && removeAttrs result.config.env ["GIT_SSH_COMMAND"] == {}
    );

    # Real-execution gate for the wrapProgram blocker (#1) + secret handling
    # (#3): build the wrapped package (over the tiny aiStubs.kimchi bin) with
    # a second env var plus a credential, and assert the wrapper sets static
    # env via --set and reads the key from its file at runtime (cat), never
    # baking the secret literal into the store. The old backslash-newline
    # separator made this build fail with exit 127 once >=2 args were present.
    module-kimchi-wrapper-builds = let
      result = evalHm {
        ai.kimchi = {
          enable = true;
          apiKey.file = "/run/secrets/kimchi-test";
          environmentVariables.KIMCHI_EXTRA = "yes";
        };
      };
      wrapped = builtins.head result.config.home.packages;
    in
      pkgs.runCommand "module-test-kimchi-wrapper-builds" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        bin=${wrapped}/bin/kimchi
        grep -q "KIMCHI_NO_UPDATE_CHECK" "$bin"
        grep -q "KIMCHI_EXTRA" "$bin"
        grep -q 'cat "/run/secrets/kimchi-test"' "$bin"
        # An empty credential file must abort the wrapper rather than let the
        # program start with the variable unset. Asserted on a REAL MCP
        # wrapper, not only glab's, because the guard lives in the shared
        # lib/credentials.nix and every server inherits it.
        grep -q 'KIMCHI_API_KEY resolved empty' "$bin"
        echo PASS > "$out"
      '';
  };
}
