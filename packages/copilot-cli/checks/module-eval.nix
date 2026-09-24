# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm lspEntryOf mcpConfigKeyOf mkTest mkWrapperGrepTest ownedDocument;
  settingsDocument = evaluated:
    ownedDocument "copilot" "${evaluated.config.ai.copilot.configDir}/settings.json" evaluated;
in {
  checks = {
    module-copilot-default-disabled = mkTest "copilot-default-disabled" (
      !(evalHm {}).config.ai.copilot.enable
      && !(evalDevenv {}).config.ai.copilot.enable
    );

    # `projectDir` remains discoverable with the same type/default in both module
    # trees, but only devenv has a project root. HM must diagnose an override
    # instead of silently interpreting it relative to HOME; devenv must consume
    # the same option for every project-native writer.
    module-copilot-project-dir-is-project-local = mkTest "copilot-project-dir-is-project-local" (
      let
        config.ai.copilot = {
          agents.reviewer = "Review the change.";
          context.text = "PROJECT-CONTEXT";
          enable = true;
          projectDir = ".custom-github";
          rules.security.text = "SECURITY-RULE";
          skills.example = ../../claude-code/checks/fixtures/claude-skills/skill-a;
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "project-local" assertion.message)
        hm.config.assertions
        && (devenv.config.files.".custom-github/copilot-instructions.md".text or "")
        == "PROJECT-CONTEXT"
        && lib.hasInfix "SECURITY-RULE"
        (devenv.config.files.".custom-github/instructions/security.instructions.md".text or "")
        && lib.hasInfix "Review the change."
        (devenv.config.files.".custom-github/agents/reviewer.agent.md".text or "")
        && devenv.config.files.".custom-github/skills/example/SKILL.md".source
        == ../../claude-code/checks/fixtures/claude-skills/skill-a/SKILL.md
        && !(devenv.config.files ? ".github/instructions/security.instructions.md")
    );

    # Copilot's normalized context/rules target github.com's project-local
    # surfaces. The HM arm keeps option parity but deliberately emits neither.
    module-copilot-hm-context-rules-are-noop = mkTest "copilot-hm-context-rules-are-noop" (
      let
        result = evalHm {
          ai = {
            context.text = "Project context";
            copilot = {
              context.text = "Copilot project context";
              enable = true;
              rules.security = {
                description = "Security guidance";
                matcher = ["**/*.ts"];
                text = "Validate all user input.";
              };
            };
            rules.shared.text = "Shared project rule.";
          };
        };
      in
        !(result.config.home.file ? ".copilot/copilot-instructions.md")
        && !(result.config.home.file ? ".copilot/instructions/security.instructions.md")
        && !(result.config.home.file ? ".copilot/instructions/shared.instructions.md")
    );

    module-copilot-devenv-context-rules-control = mkTest "copilot-devenv-context-rules-control" (
      let
        result = evalDevenv {
          ai = {
            context.text = "Project context";
            copilot = {
              context.text = "Copilot project context";
              enable = true;
              rules.security = {
                description = "Security guidance";
                matcher = ["**/*.ts"];
                text = "Validate all user input.";
              };
            };
            rules.shared.text = "Shared project rule.";
          };
        };
      in
        result.config.files.".github/copilot-instructions.md".text
        == "Project context\n\nCopilot project context"
        && result.config.files.".github/instructions/security.instructions.md".text
        == "---\napplyTo: \"**/*.ts\"\n---\n\nValidate all user input."
        && lib.hasInfix "Shared project rule."
        result.config.files.".github/instructions/shared.instructions.md".text
    );

    module-copilot-hm-context-and-rules-are-noop = mkTest "copilot-hm-context-and-rules-are-noop" (
      let
        evaluated = evalHm {
          ai = {
            copilot = {
              enable = true;
              context.text = "CONTEXT-BASELINE-TOKEN.";
              rules.named-rule = {
                matcher = ["src/**"];
                text = "NAMED-RULE-BODY-TOKEN.";
              };
            };
          };
        };
        files = evaluated.config.home.file;
      in
        !(files ? ".copilot/copilot-instructions.md")
        && !(files ? ".copilot/instructions/named-rule.instructions.md")
    );

    # Copilot devenv writes context and each keyed rule to its project-native
    # `.github/` location.
    module-copilot-devenv-context-and-rules = mkTest "copilot-devenv-context-and-rules" (
      let
        evaluated = evalDevenv {
          ai = {
            copilot = {
              enable = true;
              context.text = "CONTEXT-BASELINE-TOKEN.";
              rules = {
                named-rule = {
                  matcher = ["src/**"];
                  text = "NAMED-RULE-BODY-TOKEN.";
                };
                unnamed.text = "UNNAMED-INSTR-TOKEN.";
              };
            };
          };
        };
        contextFile = (evaluated.config.files.".github/copilot-instructions.md" or {}).text or "";
        ruleFile = evaluated.config.files.".github/instructions/named-rule.instructions.md" or null;
      in
        lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
        && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile)
        && !(evaluated.config.files ? ".config/github-copilot/copilot-instructions.md")
        && ruleFile != null
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (ruleFile.text or "")
        && lib.hasInfix "UNNAMED-INSTR-TOKEN."
        evaluated.config.files.".github/instructions/unnamed.instructions.md".text
    );

    # ── Task 4 (A3): Copilot HM/devenv fanout absorption ──────────
    module-copilot-hm-wraps-package = mkTest "copilot-hm-wraps-package" (
      let
        result = evalHm {
          ai.copilot.enable = true;
        };
        packages = result.config.home.packages;
      in
        builtins.length packages >= 1
    );

    # The declared leaves and their document are read from
    # `_reconciledDocuments`: the reconciler carries them as data in a store
    # plan, so the activation body names only the plan. The ledger path is
    # asserted because it is the live migration contract every previously
    # written ownership record hangs off.
    module-copilot-hm-empty-settings-emits-writer = mkTest "copilot-hm-empty-settings-emits-writer" (
      let
        evaluated = evalHm {ai.copilot.enable = true;};
        document = settingsDocument evaluated;
      in
        lib.hasInfix "--phase all" evaluated.config.home.activation.copilotSettingsMerge.text
        && lib.hasPrefix "json-settings/copilot-settings-" document.ledger
        && document.value == {}
    );

    module-copilot-hm-writes-settings-json-activation = mkTest "copilot-hm-writes-settings-json-activation" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.copilot.native.settings.model = "gpt-4";
        };
      in
        lib.hasInfix "--phase all" result.config.home.activation.copilotSettingsMerge.text
        && (settingsDocument result).value.model == "gpt-4"
    );

    # Copilot 1.0.88 reads repository settings from the fixed
    # `.github/copilot/settings.json` (in a trusted folder), not from
    # `configDir` and not from a configurable `projectDir`. The devenv copy is
    # a static write: no reconciler, no warning, and no file when nothing is
    # declared. The old wrapper-dir path must stay empty, or a consumer reading
    # it would believe it was delivered.
    module-copilot-devenv-writes-repository-settings = mkTest "copilot-devenv-writes-repository-settings" (
      let
        result = evalDevenv {
          ai.copilot.enable = true;
          ai.copilot.native.settings.model = "gpt-4";
        };
        empty = evalDevenv {ai.copilot.enable = true;};
        path = ".github/copilot/settings.json";
      in
        builtins.fromJSON (result.config.files.${path}.text or "null")
        == {model = "gpt-4";}
        && !(result.config.files ? ".config/github-copilot/settings.json")
        && !(empty.config.files ? ${path})
        && result.config.ai.copilot._ownPlans == {}
        && !(result.config.tasks ? "ai:copilot:settings-merge")
        && !lib.any (lib.hasInfix "ai.copilot.native.settings") result.config.warnings
    );

    # The normalized setting reaches Copilot's persisted `effortLevel` on both
    # backends. The native override is the priority control: the derived
    # mkDefault must not replace a consumer-authored native value, and an
    # explicit native null suppresses it on both. A custom `projectDir` must
    # not move the repository settings file, and a key Copilot does not accept
    # at repository scope fails evaluation rather than being written ignored.
    module-copilot-normalized-reasoning-effort = mkTest "copilot-normalized-reasoning-effort" (
      let
        path = ".github/copilot/settings.json";
        withEffort = copilot: {
          ai = {
            copilot = {enable = true;} // copilot;
            settings.reasoningEffort = "high";
          };
        };
        repository = evaluated: builtins.fromJSON (evaluated.config.files.${path}.text or "null");
        customProjectDir = evalDevenv (withEffort {projectDir = ".custom-github";});
        unsupported = evalDevenv {
          ai.copilot = {
            enable = true;
            native.settings.theme = "github";
          };
        };
      in
        (settingsDocument (evalHm (withEffort {}))).value
        == {effortLevel = "high";}
        && repository (evalDevenv (withEffort {})) == {effortLevel = "high";}
        && repository (evalDevenv (withEffort {native.settings.effortLevel = "low";})) == {effortLevel = "low";}
        && repository customProjectDir == {effortLevel = "high";}
        && !(customProjectDir.config.files ? ".custom-github/copilot/settings.json")
        && (settingsDocument (evalHm (withEffort {native.settings.effortLevel = null;}))).value == {}
        && !((evalDevenv (withEffort {native.settings.effortLevel = null;})).config.files ? ${path})
        && builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "repository settings" assertion.message
          && lib.hasInfix "theme" assertion.message)
        unsupported.config.assertions
    );

    module-copilot-hm-writes-mcp-config-json = mkTest "copilot-hm-writes-mcp-config-json" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.mcpServers.test-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
        mcpFile = result.config.home.file.".copilot/mcp-config.json" or null;
      in
        mcpFile
        != null
        && lib.hasInfix "test-server" (mcpFile.text or "")
    );

    module-copilot-hm-does-not-write-rule-files = mkTest "copilot-hm-does-not-write-rule-files" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.rules.my-rule = {
            matcher = ["src/**"];
            text = "Be concise.";
          };
        };
        files = result.config.home.file;
      in
        !(files ? ".copilot/instructions/my-rule.instructions.md")
        && !(result.config.home.file ? ".github/instructions/my-rule.instructions.md")
    );

    module-copilot-hm-writes-skills = mkTest "copilot-hm-writes-skills" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.skills.stack-fix = ../../stacked-workflows/skills/stack-fix;
        };
        skillEntry = result.config.home.file.".copilot/skills/stack-fix" or null;
      in
        skillEntry != null
    );

    module-copilot-devenv-writes-mcp-config = mkTest "copilot-devenv-writes-mcp-config" (
      let
        result = evalDevenv {
          ai.copilot.enable = true;
          ai.mcpServers.test-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
      in
        result.config.files ? ".config/github-copilot/mcp-config.json"
    );

    # The test above asserts the FILE is written — and it passed for the entire
    # life of a devenv module that never told copilot to read it. Copilot loads
    # MCP config from `$HOME/.copilot/mcp-config.json` or whatever
    # `--additional-mcp-config` points at, and NOTHING project-local: a syscall
    # trace of 1.0.78 in a project never even stats
    # `.config/github-copilot/mcp-config.json`. So writing the file is half the
    # job — and the half that matters here is that the flag points at the very
    # path the module rendered, which is why the needle is DERIVED from
    # `result.config.files` rather than spelled out.
    module-copilot-devenv-wrapper-points-at-project-mcp-config = let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      name = "copilot-devenv-wrapper-points-at-project-mcp-config";
    in
      mkWrapperGrepTest {
        inherit name;
        package =
          lib.findFirst (p: p.name == "copilot-cli-wrapped")
          (throw "devenv produced no copilot-cli-wrapped package")
          result.config.packages;
        bin = "copilot";
        needles = [
          ''--additional-mcp-config @''${DEVENV_ROOT}/${mcpConfigKeyOf name result.config.files}''
        ];
      };

    # No MCP servers → no wrapper, so a project that configures none keeps the
    # bare package and pays for no rebuild.
    # Opts out of `gitSshConfigWorkaround` for the same reason as the Kiro
    # counterpart: on devenv it lands in `environmentVariables`, which is itself
    # a wrap trigger, and this test is about the MCP gate.
    module-copilot-devenv-unwrapped-without-mcp = mkTest "copilot-devenv-unwrapped-without-mcp" (
      let
        result = evalDevenv {
          ai.copilot.enable = true;
          ai.gitSshConfigWorkaround = false;
        };
      in
        builtins.length result.config.packages
        == 1
        && (builtins.head result.config.packages).drvPath == result.config.ai.copilot.package.drvPath
        && !(lib.any (p: p.name == "copilot-cli-wrapped") result.config.packages)
    );

    # ── Task 4b: Copilot feature-gap closure ───────────────────────
    # lspServers → the `lspServers` envelope: `~/.copilot/lsp-config.json`
    # (HM, user scope) and `.github/lsp.json` (devenv, repository scope).
    module-copilot-hm-writes-lsp-config-json = mkTest "copilot-hm-writes-lsp-config-json" (
      let
        result = evalHm {
          ai.copilot = {
            enable = true;
            lspServers.typescript = {
              command = "typescript-language-server";
              args = ["--stdio"];
              extensions = ["ts"];
            };
          };
        };
      in
        lspEntryOf "lspServers" (result.config.home.file.".copilot/lsp-config.json" or null) "typescript"
        == {
          args = ["--stdio"];
          command = "typescript-language-server";
          fileExtensions.".ts" = "typescript";
        }
    );

    module-copilot-devenv-writes-lsp-json = mkTest "copilot-devenv-writes-lsp-json" (
      let
        result = evalDevenv {
          ai.copilot = {
            enable = true;
            lspServers.typescript = {
              command = "typescript-language-server";
              args = ["--stdio"];
              extensions = ["ts"];
            };
          };
        };
      in
        lspEntryOf "lspServers" (result.config.files.".github/lsp.json" or null) "typescript"
        == {
          args = ["--stdio"];
          command = "typescript-language-server";
          fileExtensions.".ts" = "typescript";
        }
        # The old inert user-scope write must be gone, not merely joined.
        && !(result.config.files ? ".config/github-copilot/lsp-config.json")
    );

    # environmentVariables → the launcher wrapper, on devenv exactly as on HM.
    # This used to assert devenv's native `env` blob; that wrote the PROJECT
    # SHELL, so the value also reached the developer's session.
    module-copilot-devenv-env-wrapper-populated = let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
        };
      };
    in
      mkWrapperGrepTest {
        name = "copilot-devenv-env-wrapper-populated";
        package = builtins.head result.config.packages;
        bin = "copilot";
        needles = ["COPILOT_MODEL" "claude-sonnet-4"];
      };

    # Configuring MCP servers PRODUCES a wrapper. That is all this asserts: one
    # entry in home.packages, carrying the wrapped derivation's name.
    #
    # It was called `...-wrapper-injects-mcp-config-flag`, which claimed a great
    # deal more than it checked — nothing here reaches the flag, and the wrapper
    # shipped broken twice underneath a green result. The flag's VALUE is now
    # asserted by `module-copilot-hm-wrapper-points-at-mcp-config` below, and its
    # argv behavior by packages/copilot-cli/checks/copilot-wrapper-argv.nix. Deliberately NOT
    # strengthened: "the trigger produces a wrapper" is a real and separate
    # thing to know, and duplicating the other two would only make three tests
    # fail together.
    module-copilot-hm-mcp-servers-produce-wrapper = mkTest "copilot-hm-mcp-servers-produce-wrapper" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.mcpServers.test-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
        packages = result.config.home.packages;
        first = builtins.head packages;
      in
        builtins.length packages
        == 1
        && first.name == "copilot-cli-wrapped"
    );

    # The wiring counterpart on the HM side: the flag must point at the very
    # path this module rendered mcp-config.json to.
    #
    # The previous version of this test matched only `@''${HOME}/` — the PREFIX —
    # so it could not have caught a `configDir` change that moved the rendered
    # file out from under the flag. Deriving the needle from
    # `result.config.home.file` closes that: both ends move together, and only a
    # divergence fails.
    module-copilot-hm-wrapper-points-at-mcp-config = let
      result = evalHm {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      name = "copilot-hm-wrapper-points-at-mcp-config";
    in
      mkWrapperGrepTest {
        inherit name;
        package = builtins.head result.config.home.packages;
        bin = "copilot";
        needles = [
          ''--additional-mcp-config @''${HOME}/${mcpConfigKeyOf name result.config.home.file}''
        ];
      };

    # Configuring env vars PRODUCES a wrapper — the second, independent trigger.
    # Renamed from `...-wrapper-exports-env-vars`: it never observed an export.
    # That the values actually reach the process is asserted by
    # packages/copilot-cli/checks/copilot-wrapper-argv.nix, which runs the wrapper and reads its
    # environment.
    module-copilot-hm-env-vars-produce-wrapper = mkTest "copilot-hm-env-vars-produce-wrapper" (
      let
        result = evalHm {
          ai.copilot = {
            enable = true;
            environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
          };
        };
        packages = result.config.home.packages;
        first = builtins.head packages;
      in
        builtins.length packages
        == 1
        && first.name == "copilot-cli-wrapped"
    );

    # No wrapper when there's nothing to wrap (no env vars, no MCP
    # servers) — we should get the raw package through.
    module-copilot-hm-no-wrapper-when-nothing-to-wrap = mkTest "copilot-hm-no-wrapper-when-nothing-to-wrap" (
      let
        result = evalHm {
          ai.copilot.enable = true;
        };
        packages = result.config.home.packages;
        first = builtins.head packages;
      in
        builtins.length packages
        == 1
        && first.drvPath == result.config.ai.copilot.package.drvPath
        && first.name != "copilot-cli-wrapped"
    );

    # agents → per-file writes under configDir.
    module-copilot-hm-writes-agent-files = mkTest "copilot-hm-writes-agent-files" (
      let
        result = evalHm {
          ai.copilot = {
            enable = true;
            agents.reviewer = "# Reviewer\n\nReview code carefully.";
          };
        };
        agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
      in
        agentFile
        != null
        && lib.hasInfix "Review code carefully" (agentFile.text or "")
    );

    module-copilot-devenv-writes-agent-files = mkTest "copilot-devenv-writes-agent-files" (
      let
        result = evalDevenv {
          ai.copilot = {
            enable = true;
            agents.reviewer = "# Reviewer\n\nReview code carefully.";
          };
        };
        agentFile = result.config.files.".github/agents/reviewer.agent.md" or null;
      in
        agentFile
        != null
        && lib.hasInfix "Review code carefully" (agentFile.text or "")
    );

    # Copilot HM keeps the normalized rule option but emits no project artifact.
    module-copilot-hm-does-not-write-rules = mkTest "copilot-hm-does-not-write-rules" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.rules.security = {
            text = "Validate all user input.";
            matcher = ["**/*.ts"];
          };
        };
        files = result.config.home.file;
      in
        !(files ? ".copilot/instructions/security.instructions.md")
        && !(result.config.home.file ? ".github/instructions/security.instructions.md")
    );

    # Copilot HM context is a documented no-op.
    module-copilot-hm-does-not-write-context = mkTest "copilot-hm-does-not-write-context" (
      let
        result = evalHm {
          ai.copilot = {
            enable = true;
            context.text = "Copilot-specific context.";
          };
        };
        files = result.config.home.file;
      in
        !(files ? ".copilot/copilot-instructions.md")
    );

    # Root context likewise does not fan to the Copilot HM product.
    module-copilot-hm-does-not-write-root-context = mkTest "copilot-hm-does-not-write-root-context" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.context.text = "Top-level context flows everywhere.";
        };
        files = result.config.home.file;
      in
        !(files ? ".copilot/copilot-instructions.md")
    );

    # Copilot devenv parity.
    module-copilot-devenv-writes-context = mkTest "copilot-devenv-writes-context" (
      let
        result = evalDevenv {
          ai.copilot = {
            enable = true;
            context.text = "Copilot devenv context.";
          };
        };
        contextFile =
          result.config.files.".github/copilot-instructions.md" or null;
      in
        contextFile
        != null
        && lib.hasInfix "Copilot devenv context" (contextFile.text or "")
    );

    # HM: top-level ai.lspServers fans out to Copilot's lsp-config.json.
    module-copilot-hm-top-level-lsp-fanout = mkTest "copilot-hm-top-level-lsp-fanout" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
            extensions = ["ts"];
          };
        };
      in
        (lspEntryOf "lspServers" (result.config.home.file.".copilot/lsp-config.json" or null) "typescript").command or null
        == "typescript-language-server"
    );

    # Devenv: top-level ai.lspServers fans out to Copilot's .github/lsp.json.
    module-copilot-devenv-top-level-lsp-fanout = mkTest "copilot-devenv-top-level-lsp-fanout" (
      let
        result = evalDevenv {
          ai.copilot.enable = true;
          ai.lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
            extensions = ["ts"];
          };
        };
      in
        (lspEntryOf "lspServers" (result.config.files.".github/lsp.json" or null) "typescript").command or null
        == "typescript-language-server"
    );

    # HM: top-level ai.environmentVariables fans out to the Copilot wrapper.
    # Same reasoning as the Kiro counterpart above — the value, not merely the
    # wrapper's existence, is what the name promises.
    module-copilot-hm-top-level-env-fanout = let
      result = evalHm {
        ai.copilot.enable = true;
        ai.environmentVariables.COPILOT_FOO = "copilot-hm-fanout-sentinel";
      };
    in
      mkWrapperGrepTest {
        name = "copilot-hm-top-level-env-fanout";
        package = builtins.head result.config.home.packages;
        bin = "copilot";
        needles = ["COPILOT_FOO" "copilot-hm-fanout-sentinel"];
      };

    # Devenv: top-level ai.environmentVariables fans to the Copilot wrapper.
    module-copilot-devenv-top-level-env-fanout = let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.environmentVariables.COPILOT_DEBUG = "copilot-devenv-fanout-sentinel";
      };
    in
      mkWrapperGrepTest {
        name = "copilot-devenv-top-level-env-fanout";
        package = builtins.head result.config.packages;
        bin = "copilot";
        needles = ["COPILOT_DEBUG" "copilot-devenv-fanout-sentinel"];
      };

    # Copilot HM: typed LSP with `extensions` emits the fileExtensions
    # mapping, keyed by dotted extension.
    module-copilot-hm-lsp-file-extensions = mkTest "copilot-hm-lsp-file-extensions" (
      let
        result = evalHm {
          ai.copilot = {
            enable = true;
            lspServers.typescript = {
              command = "typescript-language-server";
              args = ["--stdio"];
              extensions = ["ts" "tsx"];
            };
          };
        };
      in
        (lspEntryOf "lspServers" (result.config.home.file.".copilot/lsp-config.json" or null) "typescript").fileExtensions or null
        == {
          ".ts" = "typescript";
          ".tsx" = "typescript";
        }
    );

    # Copilot marks `fileExtensions` Required, so a server without
    # `extensions` must fail evaluation instead of rendering a file Copilot
    # rejects whole.
    module-copilot-lsp-without-extensions-throws = mkTest "copilot-lsp-without-extensions-throws" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.lspServers.nixd.command = "nixd";
        };
      in
        !(builtins.tryEval result.config.home.file.".copilot/lsp-config.json".text).success
    );

    # Copilot rejects the whole file when a server name holds anything but
    # ASCII letters, digits, `_` and `-`, and the name is the attribute key,
    # so a quoted "nix.lsp" must fail evaluation. The same config renamed to
    # "nix_lsp-1" must render: that is the positive control, and it pins
    # `_` and `-` as accepted.
    module-copilot-lsp-invalid-name-throws = mkTest "copilot-lsp-invalid-name-throws" (
      let
        fileFor = name:
          (evalHm {
            ai.copilot.enable = true;
            ai.lspServers.${name} = {
              command = "nixd";
              extensions = ["nix"];
            };
          }).config.home.file.".copilot/lsp-config.json";
      in
        (lspEntryOf "lspServers" (fileFor "nix_lsp-1") "nix_lsp-1").command or null
        == "nixd"
        && !(builtins.tryEval (fileFor "nix.lsp").text).success
    );

    # HM: top-level ai.agents fans out to Copilot's agents file write.
    module-copilot-hm-top-level-agents-fanout = mkTest "copilot-hm-top-level-agents-fanout" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.agents.reviewer = "# Reviewer";
        };
        agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
      in
        agentFile
        != null
        && lib.hasInfix "Reviewer" (agentFile.text or "")
    );

    module-copilot-hm-path-agent-resolves-to-text = mkTest "copilot-hm-path-agent-resolves-to-text" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.agents.reviewer = ../../claude-code/checks/fixtures/claude-agents/agent-one.md;
        };
        agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
      in
        agentFile
        != null
        && (agentFile.text or null) == builtins.readFile ../../claude-code/checks/fixtures/claude-agents/agent-one.md
    );

    # Devenv: top-level ai.agents fans out to Copilot's .github/agents.
    module-copilot-devenv-top-level-agents-fanout = mkTest "copilot-devenv-top-level-agents-fanout" (
      let
        result = evalDevenv {
          ai.copilot.enable = true;
          ai.agents.reviewer = "# Reviewer";
        };
        agentFile = result.config.files.".github/agents/reviewer.agent.md" or null;
      in
        agentFile
        != null
        && lib.hasInfix "Reviewer" (agentFile.text or "")
    );

    # A store-path STRING is a file, not Markdown: a flake input's
    # "${src}/agent.md", or an agentsDir given as a string (whose entries are
    # then strings too). Both backends must deliver the file's contents, not a
    # file whose body is the literal /nix/store path.
    module-copilot-store-string-agent-both-backends = mkTest "copilot-store-string-agent-both-backends" (
      let
        fixtureDir = "${../../claude-code/checks/fixtures/claude-agents}";
        expected = builtins.readFile ../../claude-code/checks/fixtures/claude-agents/agent-one.md;
        config.ai.copilot = {
          enable = true;
          agents.store-string = "${fixtureDir}/agent-one.md";
          agentsDir = {
            path = fixtureDir;
            filter = name: name == "agent-one.md";
          };
        };
        hmFiles = (evalHm config).config.home.file;
        devenvFiles = (evalDevenv config).config.files;
        delivered = file: (file.text or null) == expected;
      in
        delivered hmFiles.".copilot/agents/store-string.md"
        && delivered hmFiles.".copilot/agents/agent-one.md"
        && delivered devenvFiles.".github/agents/store-string.agent.md"
        && delivered devenvFiles.".github/agents/agent-one.agent.md"
    );

    # Copilot parity (HM side).
    module-copilot-agentsdir-path-form = mkTest "copilot-agentsdir-path-form" (
      let
        result = evalHm {
          ai.copilot = {
            enable = true;
            agentsDir = ../../claude-code/checks/fixtures/claude-agents;
          };
        };
        files = result.config.home.file;
      in
        files
      ? ".copilot/agents/agent-one.md"
        && files ? ".copilot/agents/agent-two.md"
    );
  };
}
