# End-to-end module contracts for github.com Copilot (`ai.copilot.github`);
# the shared harness discovers every backend. The generated ai-warnings
# matrix covers the surfaces the record declares unsupported.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm fromGeneratedTree markdownInput mkTest ownPlan;
  agentFixtures = ../../claude-code/checks/fixtures/claude-agents;
  agentOne = builtins.readFile "${agentFixtures}/agent-one.md";
  skillFixture = ../../claude-code/checks/fixtures/claude-skills/skill-a;
  # One of every surface github.com reads, each carrying its own token.
  populated = {
    ai = {
      context.text = "ROOT-CONTEXT";
      copilot = {
        enable = true;
        github = {
          agents.reviewer = {
            description = "Reviews the change";
            instructions.text = "REVIEWER-BODY";
            tools = ["read" "search"];
          };
          context.text = "COPILOT-CONTEXT";
          rules.security = {
            matcher = ["**/*.ts"];
            text = "SECURITY-RULE";
          };
        };
      };
      skills.example = skillFixture;
    };
  };
  writerTargets = evaluated: let
    inherit (ownPlan "copilot" "ai:copilot:materialize-instructions" evaluated) targets;
  in
    lib.listToAttrs (map (target: lib.nameValuePair target.path target) targets);
in {
  checks = {
    module-copilot-default-disabled = mkTest "copilot-default-disabled" (
      !(evalHm {}).config.ai.copilot.enable
      && !(evalDevenv {}).config.ai.copilot.enable
    );

    # No launcher ships: the record has no package, so the reserved `cli`
    # namespace declares nothing, `enable` is the root switch, and neither
    # backend installs anything. None of the files the Copilot CLI read are
    # written any more.
    module-copilot-no-launcher = mkTest "copilot-no-launcher" (
      let
        hm = evalHm populated;
        devenv = evalDevenv populated;
        files = deliveredFiles devenv.config;
      in
        !(hm.options.ai.copilot ? cli)
        && !(devenv.options.ai.copilot ? cli)
        && !(devenv.options.ai.copilot ? package)
        && lib.all (package: !(lib.hasInfix "copilot" (lib.getName package))) (hm.config.home.packages ++ devenv.config.packages)
        && lib.all (path: !(files ? ${path})) [
          ".config/github-copilot/mcp-config.json"
          ".github/copilot/settings.json"
          ".github/lsp.json"
        ]
    );

    # The pools live under `ai.copilot.github`, not the runtime root.
    module-copilot-github-namespace = mkTest "copilot-github-namespace" (
      let
        options = (evalDevenv {}).options.ai.copilot;
      in
        lib.all (pool: options.github ? ${pool} && !(options ? ${pool})) ["agents" "agentsDir" "context" "rules" "rulesDir"]
        && options.github.normalized ? context
        && lib.all (pool: !(options.github ? ${pool})) ["environmentVariables" "mcpServers" "settings" "shell" "skills" "skillsDir"]
    );

    # Home Manager has no repository: it writes nothing and warns for every
    # surface github.com reads.
    module-copilot-hm-writes-nothing = mkTest "copilot-hm-writes-nothing" (
      let
        result = evalHm populated;
        warnings = result.config.warnings;
        warns = path: lib.any (lib.hasPrefix "${path} is set but hm does not deliver it to copilot") warnings;
      in
        lib.all (path: !(lib.hasPrefix ".copilot" path) && !(lib.hasPrefix ".github" path)) (builtins.attrNames result.config.home.file)
        && result.config.ai.copilot.files == {}
        && lib.all warns ["ai.context" "ai.copilot.github.agents" "ai.copilot.github.context" "ai.copilot.github.rules" "ai.skills"]
    );

    # `projectDir` keeps one type and default in both trees, but only devenv
    # has a project root: Home Manager rejects an override, and devenv moves
    # every project writer with it. The context is not under it: github.com
    # reads AGENTS.md from the repository root.
    module-copilot-project-dir-is-project-local = mkTest "copilot-project-dir-is-project-local" (
      let
        config = lib.recursiveUpdate populated {ai.copilot.github.projectDir = ".custom-github";};
        hm = evalHm config;
        devenv = evalDevenv config;
        files = deliveredFiles devenv.config;
      in
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "project-local" assertion.message)
        hm.config.assertions
        && lib.all (path: fromGeneratedTree path files.${path}) [
          ".custom-github/agents/reviewer.md"
          ".custom-github/instructions/security.instructions.md"
        ]
        && files ? "AGENTS.md"
        && !(files ? ".github/instructions/security.instructions.md")
    );

    # The context joins the repository AGENTS.md through its one owner,
    # after the root context.
    module-copilot-devenv-context-is-agents-md = mkTest "copilot-devenv-context-is-agents-md" (
      let
        result = evalDevenv populated;
      in
        fromGeneratedTree "AGENTS.md" (deliveredFiles result.config)."AGENTS.md"
        && (markdownInput result "AGENTS.md").text == "ROOT-CONTEXT\n\nCOPILOT-CONTEXT"
        && result.config.ai.internal.agentsMdTargets.copilot == "AGENTS.md"
    );

    # Rules become path-specific instruction files with `applyTo` from their
    # scopes; an unscoped rule applies everywhere.
    module-copilot-devenv-rules = mkTest "copilot-devenv-rules" (
      let
        result = evalDevenv (lib.recursiveUpdate populated {ai.rules.shared.text = "SHARED-RULE";});
      in
        (markdownInput result ".github/instructions/security.instructions.md").text
        == "---\napplyTo: \"**/*.ts\"\n---\n\nSECURITY-RULE"
        && lib.hasInfix "applyTo: \"**\"" (markdownInput result ".github/instructions/shared.instructions.md").text
        && !(lib.hasInfix "SECURITY-RULE" (markdownInput result "AGENTS.md").text)
    );

    # An agent profile carries the frontmatter github.com reads.
    module-copilot-devenv-agent-profile = mkTest "copilot-devenv-agent-profile" (
      let
        result = evalDevenv populated;
        inherit (markdownInput result ".github/agents/reviewer.md") text;
      in
        fromGeneratedTree ".github/agents/reviewer.md" (deliveredFiles result.config).".github/agents/reviewer.md"
        && lib.hasInfix "name: \"reviewer\"" text
        && lib.hasInfix "description: \"Reviews the change\"" text
        && lib.hasInfix "tools: \"read, search\"" text
        && lib.hasInfix "REVIEWER-BODY" text
    );

    # A raw agent is a native file, delivered as its own bytes whether it is
    # a path, a store-path string or an agentsDir entry.
    module-copilot-devenv-raw-agents = mkTest "copilot-devenv-raw-agents" (
      let
        result = evalDevenv {
          ai.copilot = {
            enable = true;
            github = {
              agents = {
                path = "${agentFixtures}/agent-two.md";
                store-string = "${agentFixtures}/agent-one.md";
              };
              agentsDir = {
                path = agentFixtures;
                filter = name: name == "agent-one.md";
              };
            };
          };
        };
        files = deliveredFiles result.config;
        delivered = path: expected: fromGeneratedTree path files.${path} && (markdownInput result path).text == expected;
      in
        delivered ".github/agents/store-string.md" agentOne
        && delivered ".github/agents/agent-one.md" agentOne
        && delivered ".github/agents/path.md" (builtins.readFile "${agentFixtures}/agent-two.md")
    );

    # github.com reads the COMMITTED tree, where a store symlink dangles, so
    # instruction files and agent profiles are read-only copies, each
    # directory claimed by its ledger. The writer survives both N→0 and a
    # disable, emitting empty targets that retract the copies.
    module-copilot-devenv-copies = mkTest "copilot-devenv-copies" (
      let
        enabled = evalDevenv populated;
        disabled = evalDevenv (lib.recursiveUpdate populated {ai.copilot.enable = false;});
        empty = evalDevenv {ai.copilot.enable = true;};
        targets = writerTargets enabled;
      in
        !(enabled.config.files ? ".github/instructions/security.instructions.md")
        && !(enabled.config.files ? ".github/agents/reviewer.md")
        && targets.".github/instructions".ledger == "materialize/copilot-instructions.manifest"
        && targets.".github/instructions".units ? "security.instructions.md"
        && targets.".github/agents".ledger == "materialize/copilot-github-agents.manifest"
        && targets.".github/agents".units ? "reviewer.md"
        && lib.all (target: target.units == {}) (builtins.attrValues (writerTargets disabled))
        && lib.all (target: target.units == {}) (builtins.attrValues (writerTargets empty))
    );
  };
}
