# Kimchi's staged surfaces and agents ledger drain on both backends.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) deliveredFiles fromGeneratedTree markdownInput mkTest;
  files = import ../lib/files/default.nix {inherit lib pkgs;};
  backends = {
    devenv = harness.evalDevenv;
    hm = config: harness.evalHm (lib.mkMerge [{ai.kimchi.native.settings.region = "us";} config]);
  };
  agent = {
    description = "Reviews code";
    instructions.text = "BODY";
  };
  steps = ["two" "one" "empty" "disabled"];
  fixture = lib.genAttrs ["devenv" "hm"] (backend:
    lib.genAttrs [".config/kimchi" "custom/kimchi"] (configDir: let
      agentsDir =
        if backend == "hm"
        then "${configDir}/harness/agents"
        else ".kimchi/agents";
    in
      map (step: let
        inherit
          (backends.${backend} {
            ai.kimchi = {
              inherit configDir;
              enable = step != "disabled";
              agents = lib.genAttrs (
                if step == "two"
                then ["alpha" "reviewer"]
                else lib.optional (step == "one") "reviewer"
              ) (_: agent);
            };
          })
          config
          ;
      in {
        inherit agentsDir;
        inherit (config.ai.kimchi) legacyLedgers;
        plan = lib.filter (item: lib.hasPrefix "${agentsDir}/" item.path) (files.normalize {
          inherit backend;
          files = config.ai.files;
          namespace = "ai";
        });
        texts = lib.mapAttrs (_: entry: entry.content.text) config.ai.kimchi._generatedFiles;
      })
      steps));
in {
  checks = {
    ai-module-kimchi-agent-content-overrides = mkTest "ai-module-kimchi-agent-content-overrides" (
      lib.all (backend: let
        baseline = backends.${backend} {ai.kimchi.enable = true;};
        path =
          if backend == "hm"
          then ".config/kimchi/harness/agents/reviewer.md"
          else ".kimchi/agents/reviewer.md";
      in
        lib.all (content: let
          evaluated = backends.${backend} {
            ai.kimchi = {
              agents.reviewer = content.text or content.source;
              enable = true;
              files.${path}.content = content;
            };
          };
          inherit (evaluated) config;
          delivered = (deliveredFiles config).${path};
          choice = config.ai.files.${path}.content._choice;
        in
          delivered.${choice}
          == toString content.${choice}
          && !fromGeneratedTree path delivered
          # The tree is identical to one with no agent: no generated Markdown
          # for this path reaches formatting, guards or surface checks.
          && toString config.ai.kimchi._generatedTree == toString baseline.config.ai.kimchi._generatedTree
          && lib.all (assertion: assertion.assertion) config.assertions) [
          {text = "*   original body\n";}
          {source = "${./fixtures/probe-skill/SKILL.md}";}
        ]) (builtins.attrNames backends)
    );
    ai-module-kimchi-agents = pkgs.runCommandLocal "ai-module-kimchi-agents" {passthru.fixture = builtins.toJSON fixture;} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit])}/bin/python3 -I ${./kimchi.py} \
        ${../lib/files}/engine.py ${pkgs.writeText "kimchi-agents.json" (builtins.toJSON fixture)}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
    ai-module-kimchi-surfaces = mkTest "ai-module-kimchi-surfaces" (
      lib.all (backend: let
        configDir = "custom/kimchi";
        harnessDir =
          if backend == "hm"
          then "${configDir}/harness"
          else ".config/kimchi/harness";
        agentsDir =
          if backend == "hm"
          then "${harnessDir}/agents"
          else ".kimchi/agents";
        skillsDir =
          if backend == "hm"
          then "${harnessDir}/skills"
          else ".kimchi/skills";
        contextPath =
          if backend == "hm"
          then "${harnessDir}/custom.md"
          else "AGENTS.md";
        settings = {
          ai = {
            context.text = "ROOT";
            skills.probe = ./fixtures/probe-skill;
            kimchi = {
              inherit configDir;
              agents.reviewer = agent;
              context = {
                filename = "custom.md";
                text = "LOCAL";
              };
              enable = true;
              extensions.probe = pkgs.emptyDirectory;
            };
          };
        };
        evaluated = backends.${backend} settings;
        inherit (evaluated) config;
        delivered = deliveredFiles config;
        staged = config.ai.kimchi._generatedFiles;
        agentPath = "${agentsDir}/reviewer.md";
        extensionPath = "${harnessDir}/packages/probe";
        skillPath = "${skillsDir}/probe";
        moved = [agentPath extensionPath skillPath] ++ lib.optional (backend == "hm") contextPath;
        disabled = (backends.${backend} (lib.recursiveUpdate settings {ai.kimchi.enable = false;})).config;
        overridden = backends.${backend} (lib.recursiveUpdate settings {
          ai.kimchi.files = {
            ${agentPath}.method = "symlink";
            ${contextPath}.content.text = "REPLACEMENT";
            ${extensionPath}.enable = false;
          };
        });
        suppressed = backends.${backend} (lib.recursiveUpdate settings {
          ai.kimchi.files.${contextPath}.enable = false;
        });
        expectedLedger = {
          codec = "dir";
          ledger = "materialize/kimchi-agents-${builtins.hashString "sha256" (
            if backend == "hm"
            then configDir
            else agentsDir
          )}.manifest";
          path = agentsDir;
        };
      in
        lib.all (path:
          staged ? ${path}
          && config.ai.kimchi.files ? ${path}
          && config.ai.claims.path.${path} == ["kimchi"]
          && config.ai.files.${path}.mode == null
          && config.ai.files.${path}.executable == null)
        moved
        && lib.all (path: fromGeneratedTree path delivered.${path}) [agentPath contextPath extensionPath]
        && config.ai.files.${agentPath}.method == "ro"
        && config.ai.files.${agentPath}.format == "markdown"
        && config.ai.files.${extensionPath}.method == "symlink"
        && config.ai.files.${extensionPath}.format == "raw"
        && config.ai.files.${skillPath}.method == "symlink"
        && config.ai.files.${skillPath}.recursive
        && delivered.${"${skillPath}/SKILL.md"}.source == "${./fixtures/probe-skill}/SKILL.md"
        && delivered.${"${skillPath}/scripts/executable-probe"}.source == "${./fixtures/probe-skill}/scripts/executable-probe"
        && (markdownInput evaluated contextPath).text == "ROOT\n\nLOCAL"
        && config.ai.files.${contextPath}.method
        == (
          if backend == "hm"
          then "symlink"
          else "ro"
        )
        && lib.elem expectedLedger config.ai.kimchi.legacyLedgers
        && disabled.ai.kimchi.legacyLedgers == config.ai.kimchi.legacyLedgers
        && lib.elem expectedLedger disabled.ai.legacyLedgers
        && disabled.ai.files == {}
        && overridden.config.ai.files.${agentPath}.method == "symlink"
        && !(deliveredFiles overridden.config ? ${extensionPath})
        && overridden.config.ai.files.${contextPath}.content.text == "REPLACEMENT"
        && !(deliveredFiles suppressed.config ? ${contextPath})
        && lib.all (assertion: assertion.assertion) config.assertions) (builtins.attrNames backends)
    );
  };
}
