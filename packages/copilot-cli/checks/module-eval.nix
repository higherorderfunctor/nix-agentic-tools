# End-to-end module contracts for github.com Copilot (`ai.copilot.github`);
# the shared harness discovers every backend. The generated ai-warnings
# matrix covers the surfaces the record declares unsupported.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm fromGeneratedTree markdownInput mkTest ownPlan setEnable;
  skillFixture = ../../claude-code/checks/fixtures/claude-skills/skill-a;
  # One of every surface github.com reads, each carrying its own token.
  populated = {
    ai = {
      context.text = "ROOT-CONTEXT";
      copilot = {
        enable = true;
        github = {
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
  # The files engine's copies Copilot claims, by path.
  copies = evaluated: lib.listToAttrs (map (target: lib.nameValuePair target.path target) (ownPlan "copilot" "files-apply" evaluated).targets);
  claims = evaluated: lib.filterAttrs (_path: owners: builtins.elem "copilot" owners) evaluated.config.ai.filesOwners;
  # The old writer's ledgers, one per directory under `projectDir`, are
  # Copilot's and reach the engine's root list.
  declaresLedgers = projectDir: evaluated: let
    expected =
      map (dir: {
        codec = "dir";
        ledger = "materialize/${dir.ledger}.manifest";
        path = "${projectDir}/${dir.path}";
      }) [
        {
          ledger = "copilot-github-agents";
          path = "agents";
        }
        {
          ledger = "copilot-instructions";
          path = "instructions";
        }
      ];
  in
    evaluated.config.ai.copilot.legacyLedgers
    == expected
    && lib.all (ledger: builtins.elem ledger evaluated.config.ai.legacyLedgers) expected;
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
        lib.all (pool: options.github ? ${pool} && !(options ? ${pool})) ["context" "rules" "rulesDir"]
        && options.github.normalized ? context
        && lib.all (pool: !(options.github ? ${pool})) ["agents" "agentsDir" "environmentVariables" "mcpServers" "settings" "shell" "skills" "skillsDir"]
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
        && result.config.ai.copilot._generatedFiles == {}
        && result.config.ai.copilot.legacyLedgers == []
        # Root and per-runtime context warn once, naming the per-runtime pool.
        && lib.all warns ["ai.copilot.github.context" "ai.copilot.github.rules" "ai.skills"]
        && !(warns "ai.context")
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
        && fromGeneratedTree ".custom-github/instructions/security.instructions.md" files.".custom-github/instructions/security.instructions.md"
        && files ? "AGENTS.md"
        && !(files ? ".github/instructions/security.instructions.md")
        && declaresLedgers ".custom-github" devenv
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

    # github.com code review never reads .github/agents: a root agent warns
    # with that reason and nothing lands under `<projectDir>/agents`.
    module-copilot-devenv-agents-gap = mkTest "copilot-devenv-agents-gap" (
      let
        result = evalDevenv (lib.recursiveUpdate populated {
          ai.agents.reviewer = {
            description = "Reviews the change";
            instructions.text = "REVIEWER-BODY";
          };
        });
      in
        builtins.elem "ai.agents is set but devenv does not deliver it to copilot (reason: github.com code review never reads .github/agents.)" result.config.warnings
        && !(lib.any (lib.hasPrefix ".github/agents") (builtins.attrNames (deliveredFiles result.config)))
    );

    # github.com reads the COMMITTED tree, where a store symlink dangles, so
    # instruction files are read-only Markdown copies from Copilot's
    # generated tree, at the engine's default mode. A consumer's layer-1
    # method wins. N→0 and a disable claim nothing, and the old writer's
    # ledgers, agents included, are declared either way, so its copies drain.
    module-copilot-devenv-copies = mkTest "copilot-devenv-copies" (
      let
        enabled = evalDevenv populated;
        linked = evalDevenv (lib.recursiveUpdate populated {ai.copilot.files.".github/instructions/security.instructions.md".method = "symlink";});
        disabled = evalDevenv (lib.recursiveUpdate populated {ai.copilot.enable = false;});
        empty = evalDevenv {ai.copilot.enable = true;};
        targets = copies enabled;
        copied = path:
          targets.${path}.method
          == "ro"
          && targets.${path}.format == "markdown"
          && targets.${path}.mode == null
          && targets.${path}.executable == null
          && targets.${path}.content.source == "${enabled.config.ai.copilot._generatedTree}/${path}";
      in
        builtins.attrNames targets
        == [".github/instructions/security.instructions.md"]
        && lib.all (path: copied path && !(enabled.config.files ? ${path})) (builtins.attrNames targets)
        && linked.config.ai.files.".github/instructions/security.instructions.md".method == "symlink"
        && linked.config.files ? ".github/instructions/security.instructions.md"
        && claims disabled == {}
        && claims empty == {}
        && lib.all (declaresLedgers ".github") [disabled empty enabled]
    );

    # Ported from module-delivery-normalized-keyed-pools-extend, for the keyed
    # pools Copilot supports: an ordinary normalized definition extends the
    # inherited and local keys, and `mkForce` replaces the pool.
    module-copilot-normalized-keyed-pools-extend = mkTest "copilot-normalized-keyed-pools-extend" (
      let
        optionPaths = import ../../../lib/ai/option-paths.nix {inherit lib;};
        # Copilot's keyed pools; Codex's are ported with Codex.
        samples.rules.text = "probe";
      in
        lib.all (
          evaluate:
            lib.all (
              pool: let
                poolPath = optionPaths.pool "copilot" pool;
                normalizedPath = lib.init poolPath ++ ["normalized" pool];
                base = lib.recursiveUpdate (setEnable "copilot" true) (lib.recursiveUpdate
                  {ai.${pool}.inherited = samples.${pool};}
                  (lib.setAttrByPath (poolPath ++ ["local"]) samples.${pool}));
                original = lib.getAttrFromPath normalizedPath (evaluate base).config;
                extension.extra = original.inherited;
                result = value: (evaluate (lib.recursiveUpdate base (lib.setAttrByPath normalizedPath value))).config;
                extended = result extension;
                forced = result (lib.mkForce extension);
              in
                builtins.attrNames (lib.getAttrFromPath normalizedPath extended)
                == ["extra" "inherited" "local"]
                && (lib.getAttrFromPath normalizedPath extended).inherited == original.inherited
                && builtins.attrNames (lib.getAttrFromPath normalizedPath forced) == ["extra"]
                && lib.all (assertion: assertion.assertion) (extended.assertions ++ forced.assertions)
            ) (builtins.attrNames samples)
        ) [evalHm evalDevenv]
    );
  };
}
