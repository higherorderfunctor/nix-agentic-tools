# End-to-end module contracts for github.com Copilot (`ai.copilot.github`);
# the shared harness discovers every backend. The generated ai-warnings
# matrix covers the surfaces the record declares unsupported.
{
  lib,
  harness,
  pkgs,
  ...
}: let
  inherit (harness) checkRows deliveredFiles evalDevenv evalHm fromGeneratedTree markdownInput mkTest ownPlan;
  fileLib = import ../../ai-module/lib/files/default.nix {inherit lib pkgs;};
  skillFixture = ./fixtures/committed-skill;
  skillLeaves = ["SKILL.md" "assets/expected.txt" "reference.md" "references/deep/guide.md" "scripts/check.sh"];
  skillPaths = prefix: map (leaf: "${prefix}/${leaf}") skillLeaves;
  # The integration evaluates real runtime plans; the existing files-engine
  # safety corpus covers generic copy/refusal cases.
  skillPlan = evaluated:
    fileLib.normalize {
      backend = "devenv";
      namespace = "ai";
      files = evaluated.config.ai.files;
    };
  skillConfig = {
    ai = {
      copilot = {
        enable = true;
        github.skills.local = skillFixture;
      };
      skills.example = skillFixture;
    };
  };
  skillLifecycle = lib.mapAttrs (_: config: skillPlan (evalDevenv config)) {
    disabled = lib.recursiveUpdate skillConfig {ai.copilot.enable = false;};
    empty.ai.copilot.enable = true;
    enabled = skillConfig;
    suppressed = lib.recursiveUpdate skillConfig {ai.copilot.github.skills.example = null;};
  };
  # One of every surface github.com reads, each carrying its own token.
  populated = lib.recursiveUpdate skillConfig {
    ai = {
      context.text = "ROOT-CONTEXT";
      copilot.github = {
        context.text = "COPILOT-CONTEXT";
        rules.security = {
          matcher = ["**/*.ts"];
          text = "SECURITY-RULE";
        };
      };
    };
  };
  hmPopulated = evalHm populated;
  devPopulated = evalDevenv populated;
  contextPath = ".github/copilot-instructions.md";
  contextText = "ROOT-CONTEXT\n\nCOPILOT-CONTEXT";
  securityPath = ".github/instructions/security.instructions.md";
  readMarkdown = evaluated: path: (markdownInput evaluated path).text;
  warningFor = backend: path: lib.hasPrefix "${path} is set but ${backend} does not deliver it to copilot";
  readOnlyCopy = format: target:
    target.method == "ro" && target.format == format && target.mode == null && target.executable == null;
  # The files engine's copies Copilot claims, by path.
  copies = evaluated: lib.listToAttrs (map (target: lib.nameValuePair target.path target) (ownPlan "copilot" "files-apply" evaluated).targets);
  claims = evaluated: lib.filterAttrs (_path: owners: builtins.elem "copilot" owners) evaluated.config.ai.claims.path;
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
    # No launcher ships: the record has no package, so the reserved `cli`
    # namespace declares nothing and `enable` is the root switch. In devenv
    # no Copilot package is installed and CLI-only settings and MCP files are absent.
    module-copilot-no-launcher = mkTest "copilot-no-launcher" (
      let
        files = deliveredFiles devPopulated.config;
        hasCopilotPackage = packages: lib.any (package: lib.hasInfix "copilot" (lib.getName package)) packages;
      in
        checkRows "cloud record does not provide the CLI" {
          "devenv does not declare the reserved launcher slot or a package option" = !(devPopulated.options.ai.copilot ? cli) && !(devPopulated.options.ai.copilot ? package);
          "devenv does not install a Copilot package even when enabled" = !(hasCopilotPackage devPopulated.config.packages);
          "devenv does not write CLI settings, LSP or MCP files" = lib.all (path: !(files ? ${path})) [
            ".config/github-copilot/mcp-config.json"
            ".github/copilot/settings.json"
            ".github/lsp.json"
          ];
        }
    );

    # The pools live under `ai.copilot.github`, not the runtime root.
    module-copilot-github-namespace = mkTest "copilot-github-namespace" (
      let
        options = (evalDevenv {}).options.ai.copilot;
      in
        checkRows "github.com Copilot option namespace" {
          "CLI-only pools are not accepted under github" = lib.all (pool: !(options.github ? ${pool})) ["agents" "agentsDir" "environmentVariables" "mcpServers" "settings" "shell"];
          "cloud pools are nested under github instead of leaking to the runtime root" = lib.all (pool: options.github ? ${pool} && !(options ? ${pool})) ["context" "rules" "rulesDir" "skills" "skillsDir"];
        }
    );

    # Home Manager has no repository: it writes nothing and warns for every
    # surface github.com reads.
    module-copilot-hm-writes-nothing = mkTest "copilot-hm-writes-nothing" (
      let
        inherit (hmPopulated.config) warnings;
        warningsFor = paths:
          lib.filter (warning: lib.any (path: warningFor "hm" path warning) paths) warnings;
        warnsOnlyForLocal = shared: local:
          map (warningFor "hm" local) (warningsFor [shared local]) == [true];
      in
        checkRows "Home Manager has no repository to write" {
          "cloud content does not become Home Manager file entries" = lib.all (path: !(lib.hasPrefix ".copilot" path) && !(lib.hasPrefix ".github" path)) (builtins.attrNames hmPopulated.config.home.file);
          "cloud content is not staged and no obsolete repository ledgers are imported" = hmPopulated.config.ai.copilot._generatedFiles == {} && hmPopulated.config.ai.copilot.legacyLedgers == [];
          # The generated warning matrix delegates these both-set rows here.
          "shared and local context warn once under the local pool" = warnsOnlyForLocal "ai.context" "ai.copilot.github.context";
          "shared and local skills warn once under the local pool" = warnsOnlyForLocal "ai.skills" "ai.copilot.github.skills";
        }
    );

    # `projectDir` keeps one type and default in both trees, but only devenv
    # has a project root: Home Manager rejects an override, and devenv moves
    # every project writer with it, including the standalone context.
    module-copilot-project-dir-is-project-local = mkTest "copilot-project-dir-is-project-local" (
      let
        config = lib.recursiveUpdate populated {ai.copilot.github.projectDir = ".custom-github";};
        hm = evalHm config;
        devenv = evalDevenv config;
        files = deliveredFiles devenv.config;
      in
        checkRows "Copilot projectDir override" {
          "Home Manager accepts the default but rejects an override as project-local" =
            lib.all (assertion: assertion.assertion) hmPopulated.config.assertions
            && lib.any (assertion: !assertion.assertion && lib.hasPrefix "ai.copilot.github.projectDir is project-local" assertion.message) hm.config.assertions;
          "legacy ledgers follow projectDir along with their writers" = declaresLedgers ".custom-github" devenv;
          "named rules move without also writing the old path" =
            fromGeneratedTree ".custom-github/instructions/security.instructions.md" (files.".custom-github/instructions/security.instructions.md" or {})
            && !(files ? ${securityPath});
          "shared and runtime skill trees move without also writing under the old root" =
            lib.filter (path: lib.hasPrefix ".custom-github/skills/" path || lib.hasPrefix ".github/skills/" path) (builtins.attrNames files)
            == skillPaths ".custom-github/skills/example" ++ skillPaths ".custom-github/skills/local";
          "standalone context moves without writing the old path" =
            fromGeneratedTree ".custom-github/copilot-instructions.md" (files.".custom-github/copilot-instructions.md" or {})
            && !(files ? ${contextPath});
        }
    );

    # Unnamed shared and runtime context compose once in Copilot's own file;
    # the shared AGENTS.md owner receives no Copilot contribution.
    module-copilot-devenv-independent-context = mkTest "copilot-devenv-independent-context" (
      let
        files = deliveredFiles devPopulated.config;
        renamed = evalDevenv (lib.recursiveUpdate populated {ai.copilot.github.context.filename = "custom.md";});
        alongside = evalDevenv (lib.recursiveUpdate populated {
          ai = {
            codex = {
              enable = true;
              context.text = "LOCAL-CONTEXT";
            };
            kimchi = {
              enable = true;
              context.text = "LOCAL-CONTEXT";
            };
          };
        });
      in
        checkRows "Copilot standalone context" {
          "alongside an AGENTS.md writer both documents keep their separate sources" =
            readMarkdown alongside "AGENTS.md"
            == "ROOT-CONTEXT\n\nLOCAL-CONTEXT"
            && readMarkdown alongside contextPath == contextText;
          "context filename override does not leave a second copy at the default path" =
            readMarkdown renamed ".github/custom.md" == contextText && !((deliveredFiles renamed.config) ? ${contextPath});
          "Copilot alone does not write AGENTS.md or claim it for warning attribution" =
            !(files ? "AGENTS.md")
            && !(devPopulated.config.ai.internal.agentsMdTargets ? copilot);
        }
    );

    # Rules become path-specific instruction files with `applyTo` from their
    # scopes; an unscoped rule applies everywhere.
    module-copilot-devenv-rules = mkTest "copilot-devenv-rules" (
      let
        result = evalDevenv (lib.recursiveUpdate populated {
          ai.rules.shared.text = "SHARED-RULE";
        });
      in
        checkRows "Copilot path-specific instructions" {
          "named rules do not leak into standalone context" = readMarkdown result contextPath == contextText;
          "unscoped inherited rule retains its body and applies everywhere" = readMarkdown result ".github/instructions/shared.instructions.md" == "---\napplyTo: \"**\"\n---\n\nSHARED-RULE";
        }
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
    # method wins. An enabled owner with no inputs claims nothing. The old
    # writer's ledgers, agents included, are declared for both empty enabled
    # and disabled owners, so its copies drain.
    module-copilot-devenv-copies = mkTest "copilot-devenv-copies" (
      let
        linked = evalDevenv (lib.recursiveUpdate populated {ai.copilot.files.${securityPath}.method = "symlink";});
        disabled = evalDevenv (lib.recursiveUpdate populated {ai.copilot.enable = false;});
        empty = evalDevenv {ai.copilot.enable = true;};
        targets = lib.filterAttrs (path: _: lib.hasPrefix ".github/" path && lib.hasSuffix ".md" path && !(lib.hasPrefix ".github/skills/" path)) (copies devPopulated);
        copied = path:
          readOnlyCopy "markdown" targets.${path}
          && targets.${path}.content.source == "${devPopulated.config.ai.copilot._generatedTree}/${path}";
        instructionPaths = [contextPath securityPath];
      in
        checkRows "files-engine routing for committed instructions" {
          "a layer-one method override makes the rule a native link" =
            linked.config.ai.files.${securityPath}.method == "symlink" && linked.config.files ? ${securityPath};
          "disabled Copilot still declares migration ledgers" = declaresLedgers ".github" disabled;
          "enabled empty Copilot leaves no path claims but still declares migration ledgers" = claims empty == {} && declaresLedgers ".github" empty;
          "instructions are engine-owned read-only Markdown from the generated tree, never parallel native links" =
            builtins.attrNames targets
            == instructionPaths
            && lib.all (path: copied path && !(devPopulated.config.files ? ${path})) instructionPaths;
        }
    );

    module-copilot-devenv-skills = mkTest "copilot-devenv-skills" (
      let
        targets = lib.filterAttrs (path: _: lib.hasPrefix ".github/skills/" path) (copies devPopulated);
        overridden = evalDevenv (lib.recursiveUpdate populated {
          ai.copilot.files.".github/skills/example".method = "symlink";
        });
        single = evalDevenv {
          ai.skills.single = skillFixture;
          ai.copilot = {
            enable = true;
            github.skills.single = skillFixture + "/SKILL.md";
          };
        };
        directory = evalDevenv {
          ai.copilot = {
            enable = true;
            github.skillsDir = ./fixtures;
          };
        };
      in
        checkRows "files-engine routing for committed skills" {
          "a layer-one method override makes directory leaves native links" =
            overridden.config.ai.files.".github/skills/example".method
            == "symlink"
            && overridden.config.files ? ".github/skills/example/SKILL.md";
          "a same-key single-file runtime replacement discards all the root skill's other leaves" =
            builtins.attrNames (copies single)
            == [".github/skills/single/SKILL.md"]
            && fromGeneratedTree ".github/skills/single/SKILL.md" (deliveredFiles single.config).".github/skills/single/SKILL.md";
          "directory discovery uses the folder name to stage every leaf" = builtins.attrNames (copies directory) == skillPaths ".github/skills/committed-skill";
          # Python checks the resulting members on disk; this guards the routing
          # of each member, which the runtime engine cannot see for native links.
          "recursive skill leaves use raw read-only copies without parallel native links or mode overrides" =
            lib.all (path: targets ? ${path} && readOnlyCopy "raw" targets.${path} && !(devPopulated.config.files ? ${path}))
            (skillPaths ".github/skills/example" ++ skillPaths ".github/skills/local");
        }
    );

    module-copilot-skills-lifecycle = pkgs.runCommandLocal "module-copilot-skills-lifecycle" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 -I ${./skills-lifecycle.py} \
        ${../../ai-module/lib/files}/engine.py \
        ${pkgs.writeText "copilot-skills-plans.json" (builtins.toJSON skillLifecycle)} \
        ${skillFixture}
      touch "$out"
    '';

    # Ported from module-delivery-normalized-keyed-pools-extend, for the keyed
    # pools Copilot supports: an ordinary normalized definition extends the
    # inherited and local keys, and `mkForce` replaces the pool.
    module-copilot-normalized-keyed-pools-extend = mkTest "copilot-normalized-keyed-pools-extend" (
      let
        samples = {
          rules = {
            input = text: {inherit text;};
            observe = rule: rule.text;
            expected = {
              extra = "additional rule";
              inherited = "inherited rule";
              local = "runtime rule";
            };
          };
          skills = {
            input = lib.id;
            observe = lib.id;
            expected = {
              extra = skillFixture + "/reference.md";
              inherited = skillFixture;
              local = skillFixture + "/SKILL.md";
            };
          };
        };
        rows = lib.mapAttrs' (pool: sample: let
          inputs = lib.mapAttrs (_: sample.input) sample.expected;
          base.ai = {
            ${pool}.inherited = inputs.inherited;
            copilot = {
              enable = true;
              github.${pool}.local = inputs.local;
            };
          };
          extension = {inherit (inputs) extra;};
          result = value: (evalDevenv (lib.recursiveUpdate base {ai.copilot.github.normalized.${pool} = value;})).config;
          observe = config: lib.mapAttrs (_: sample.observe) config.ai.copilot.github.normalized.${pool};
          extended = result extension;
          forced = result (lib.mkForce extension);
        in
          lib.nameValuePair "${pool} additions retain inherited and local entries, mkForce retains only the replacement" (
            observe extended
            == sample.expected
            && observe forced == {inherit (sample.expected) extra;}
            && lib.all (assertion: assertion.assertion) (extended.assertions ++ forced.assertions)
          ))
        samples;
      in
        checkRows "Copilot keyed normalized pool overrides in devenv" rows
    );
  };
}
