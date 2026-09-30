# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm fromGeneratedTree lspEntryOf markdownInput mcpConfigKeyOf mkTest mkWrapperGrepTest ownedDocument ownPlan;
  # The one directory target of Copilot's config writer: `configDir` on Home
  # Manager, `.github/copilot` on devenv. Its units are whole files, so a
  # check reads the declared bytes and the ledger of each. `ownPlan` throws
  # on an absent writer, so a renamed entry fails the check.
  configTarget = entry: evaluated: let
    inherit (ownPlan "copilot" entry evaluated) targets;
  in
    lib.throwIfNot (lib.length targets == 1)
    "Copilot check requires exactly one target for ${entry}, found ${toString (lib.length targets)}"
    (lib.head targets);
  hmConfigTarget = configTarget "materialize-copilot-config";
  devenvConfigTarget = configTarget "ai:copilot:materialize-config";
  # A copy's declared JSON, before its generated tree renders the bytes.
  fileValue = evaluated: path: evaluated.config.ai.copilot.files.${path}.content.value;
  hmSettings = evaluated: fileValue evaluated "${evaluated.config.ai.copilot.configDir}/settings.json";
  repositorySettings = evaluated: let
    target = devenvConfigTarget evaluated;
    path = "${target.path}/settings.json";
  in
    if target.units ? "settings.json"
    then fileValue evaluated path
    else null;
  failedAssertions = evaluated:
    map (assertion: assertion.message)
    (lib.filter (assertion: !assertion.assertion) evaluated.config.assertions);
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
        && lib.all (path: fromGeneratedTree path (deliveredFiles devenv.config).${path}) [
          ".custom-github/copilot-instructions.md"
          ".custom-github/instructions/security.instructions.md"
          ".custom-github/agents/reviewer.agent.md"
        ]
        && (markdownInput devenv ".custom-github/copilot-instructions.md").text
        == "PROJECT-CONTEXT"
        && lib.hasInfix "SECURITY-RULE"
        (markdownInput devenv ".custom-github/instructions/security.instructions.md").text
        && lib.hasInfix "Review the change."
        (markdownInput devenv ".custom-github/agents/reviewer.agent.md").text
        && (deliveredFiles devenv.config).".custom-github/skills/example/SKILL.md".source
        == "${config.ai.copilot.skills.example}/SKILL.md"
        && !((deliveredFiles devenv.config) ? ".github/instructions/security.instructions.md")
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
        fromGeneratedTree ".github/copilot-instructions.md" (deliveredFiles result.config).".github/copilot-instructions.md"
        && (markdownInput result ".github/copilot-instructions.md").text
        == "Project context\n\nCopilot project context"
        && (markdownInput result ".github/instructions/security.instructions.md").text
        == "---\napplyTo: \"**/*.ts\"\n---\n\nValidate all user input."
        && lib.hasInfix "Shared project rule."
        (markdownInput result ".github/instructions/shared.instructions.md").text
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
        contextFile = (markdownInput evaluated ".github/copilot-instructions.md").text;
      in
        lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
        && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile)
        && !((deliveredFiles evaluated.config) ? ".config/github-copilot/copilot-instructions.md")
        && fromGeneratedTree ".github/instructions/named-rule.instructions.md" (deliveredFiles evaluated.config).".github/instructions/named-rule.instructions.md"
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (markdownInput evaluated ".github/instructions/named-rule.instructions.md").text
        && lib.hasInfix "UNNAMED-INSTR-TOKEN."
        (markdownInput evaluated ".github/instructions/unnamed.instructions.md").text
    );

    # github.com reads the COMMITTED tree, where a store symlink dangles, so
    # on devenv the repository context and instruction files are read-only
    # copies, each claimed by a directory ledger. The writer survives both
    # N→0 and a disable, emitting empty targets that retract the copies.
    module-copilot-devenv-instructions-are-copies = mkTest "copilot-devenv-instructions-are-copies" (
      let
        config = enable: {
          ai.copilot = {
            context.text = "CTX";
            inherit enable;
            rules.scoped = {
              matcher = ["src/**"];
              text = "RULE";
            };
          };
        };
        enabled = evalDevenv (config true);
        disabled = evalDevenv (config false);
        empty = evalDevenv {ai.copilot.enable = true;};
        targets = evaluated: (ownPlan "copilot" "ai:copilot:materialize-instructions" evaluated).targets;
        byPath = evaluated: lib.listToAttrs (map (target: lib.nameValuePair target.path target) (targets evaluated));
      in
        !(enabled.config.files ? ".github/copilot-instructions.md")
        && !(enabled.config.files ? ".github/instructions/scoped.instructions.md")
        && fromGeneratedTree ".github/copilot-instructions.md" {source = (byPath enabled).".github".units."copilot-instructions.md".store;}
        && (markdownInput enabled ".github/copilot-instructions.md").text == "CTX"
        && (byPath enabled).".github".ledger == "materialize/copilot-context.manifest"
        && fromGeneratedTree ".github/instructions/scoped.instructions.md" {source = (byPath enabled).".github/instructions".units."scoped.instructions.md".store;}
        && lib.hasInfix "RULE" (markdownInput enabled ".github/instructions/scoped.instructions.md").text
        && (byPath enabled).".github/instructions".ledger == "materialize/copilot-instructions.manifest"
        && lib.all (target: target.units == {}) (targets disabled)
        && lib.all (target: target.units == {}) (targets empty)
    );

    # ── Copilot HM/devenv fanout ──────────────────────────────────
    module-copilot-hm-wraps-package = mkTest "copilot-hm-wraps-package" (
      let
        result = evalHm {
          ai.copilot.enable = true;
        };
        packages = result.config.home.packages;
      in
        builtins.length packages >= 1
    );

    # Copilot renames a temporary over its settings files, so Home Manager
    # owns each user-global one as a whole read-only copy of one directory
    # writer, declared and populated even when nothing is: `{}` settings and
    # empty server maps. Nothing reaches them as a store link.
    module-copilot-hm-empty-settings-emits-writer = mkTest "copilot-hm-empty-settings-emits-writer" (
      let
        evaluated = evalHm {ai.copilot.enable = true;};
        target = hmConfigTarget evaluated;
      in
        target.path
        == ".copilot"
        && target.ledger == "materialize/copilot-config.manifest"
        && fileValue evaluated ".copilot/settings.json" == {}
        && fileValue evaluated ".copilot/mcp-config.json" == {mcpServers = {};}
        && fileValue evaluated ".copilot/lsp-config.json" == {lspServers = {};}
        && lib.all (name: evaluated.config.ai.copilot.files.".copilot/${name}".method == "copy-ro") (lib.attrNames target.units)
        && evaluated.config.home.activation ? "materialize-copilot-config"
        && evaluated.config.home.activation ? "materialize-copilot-config-prune"
        && !lib.any (path: evaluated.config.home.file ? ${path}) [
          ".copilot/lsp-config.json"
          ".copilot/mcp-config.json"
          ".copilot/settings.json"
        ]
    );

    module-copilot-hm-writes-settings-json-activation = mkTest "copilot-hm-writes-settings-json-activation" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.copilot.native.settings.model = "gpt-4";
        };
      in
        result.config.home.activation
        ? "materialize-copilot-config"
        && hmSettings result == {model = "gpt-4";}
    );

    # Copilot 1.0.88 reads repository settings from the fixed
    # `.github/copilot/settings.json` (in a trusted folder), not from
    # `configDir` and not from a configurable `projectDir`. Its own
    # `/settings --repo` and `/model --repo` write that file, so devenv
    # delivers a read-only copy the next shell entry restores. The writer
    # stays declared with nothing declared and while Copilot is disabled, so
    # both retract the copy, and a project that declares nothing keeps a
    # committed team file. The old wrapper-dir path must stay empty, or a
    # consumer reading it would believe it was delivered.
    module-copilot-devenv-repository-settings-are-copies = mkTest "copilot-devenv-repository-settings-are-copies" (
      let
        declared = enable:
          evalDevenv {
            ai.copilot = {
              inherit enable;
              native.settings.model = "gpt-4";
            };
          };
        result = declared true;
        target = devenvConfigTarget result;
        path = ".github/copilot/settings.json";
      in
        target.path
        == ".github/copilot"
        && target.ledger == "materialize/copilot-config.manifest"
        && repositorySettings result == {model = "gpt-4";}
        && result.config.ai.copilot.files.${path}.method == "copy-ro"
        && (devenvConfigTarget (evalDevenv {ai.copilot.enable = true;})).units == {}
        && (devenvConfigTarget (declared false)).units == {}
        && (declared false).config.tasks ? "ai:copilot:materialize-config"
        && result.config.tasks ? "ai:copilot:materialize-config"
        && !(result.config.files ? ${path})
        && !(result.config.files ? ".config/github-copilot/settings.json")
        && !lib.any (lib.hasInfix "ai.copilot.native.settings") result.config.warnings
    );

    # Copilot keeps folder trust only in its state file. Home Manager owns the
    # `trustedFolders` leaf of it, empty list included, and nothing else there;
    # it is the only Copilot file delivered as a shared document. The writer
    # survives a disable, which retracts the leaf.
    module-copilot-hm-owns-trusted-folders = mkTest "copilot-hm-owns-trusted-folders" (
      let
        evaluate = copilot: evalHm {ai.copilot = {enable = true;} // copilot;};
        path = ".copilot/config.json";
        empty = ownedDocument "copilot" path (evaluate {});
        shared = evaluated:
          lib.attrNames (lib.filterAttrs (_path: file: file != null && file.facts.harnessWrites)
            evaluated.config.ai.copilot.files);
        disabled = evalHm {ai.copilot.trustedFolders = ["/src"];};
      in
        empty.value
        == {trustedFolders = [];}
        && lib.hasPrefix "json-settings/copilot-config-" empty.ledger
        && (ownedDocument "copilot" path (evaluate {trustedFolders = ["/src"];})).value == {trustedFolders = ["/src"];}
        && shared (evaluate {}) == [path]
        && disabled.config.home.activation ? copilotTrustedFolders
        && !(disabled.config.ai.copilot.files ? ${path})
        && failedAssertions (evaluate {trustedFolders = ["/src"];}) == []
    );

    # A relative folder can never match the absolute working directory
    # Copilot compares, and devenv never writes the user-global state file,
    # so both fail evaluation naming the option.
    module-copilot-trusted-folders-assertions = mkTest "copilot-trusted-folders-assertions" (
      let
        names = messages: messages != [] && lib.all (lib.hasInfix "ai.copilot.trustedFolders") messages;
        devenv = evalDevenv {
          ai.copilot = {
            enable = true;
            trustedFolders = ["/x"];
          };
        };
        relative = failedAssertions (evalHm {
          ai.copilot = {
            enable = true;
            trustedFolders = ["src"];
          };
        });
      in
        names relative
        && lib.any (lib.hasInfix "src") relative
        && names (failedAssertions devenv)
        && !(devenv.config.ai.copilot._ownPlans ? copilotTrustedFolders)
        && failedAssertions (evalDevenv {ai.copilot.enable = true;}) == []
    );

    # The normalized setting reaches Copilot's persisted `effortLevel` on both
    # backends. The native override is the priority control: the derived
    # mkDefault must not replace a consumer-authored native value, and an
    # explicit native null suppresses it on both. A custom `projectDir` must
    # not move the repository settings file.
    module-copilot-normalized-reasoning-effort = mkTest "copilot-normalized-reasoning-effort" (
      let
        path = ".github/copilot/settings.json";
        withEffort = copilot: {
          ai = {
            copilot = {enable = true;} // copilot;
            settings.reasoningEffort = "high";
          };
        };
        customProjectDir = evalDevenv (withEffort {projectDir = ".custom-github";});
      in
        hmSettings (evalHm (withEffort {}))
        == {effortLevel = "high";}
        && repositorySettings (evalDevenv (withEffort {})) == {effortLevel = "high";}
        && repositorySettings (evalDevenv (withEffort {native.settings.effortLevel = "low";})) == {effortLevel = "low";}
        && repositorySettings customProjectDir == {effortLevel = "high";}
        && (deliveredFiles customProjectDir.config) ? ${path}
        && !((deliveredFiles customProjectDir.config) ? ".custom-github/copilot/settings.json")
        && hmSettings (evalHm (withEffort {native.settings.effortLevel = null;})) == {}
        # Nothing left to declare, so devenv claims no repository file.
        && repositorySettings (evalDevenv (withEffort {native.settings.effortLevel = null;})) == null
    );

    # The repository schema, as copilot-cli 1.0.88's `runtime.node` reports
    # it (`userSettingsGovernanceKeys().repo` for the names,
    # `userSettingsMetadata()` for the value kinds). Copilot drops a name
    # outside it one key at a time, and ignores the WHOLE file when a known
    # key has a value of the wrong type. devenv rejects both at evaluation:
    # every schema key with a valid value passes, `autoTier` included, while
    # a user-only name and a mistyped value each fail naming the key. Home
    # Manager's user file is not restricted.
    module-copilot-repository-settings-schema = mkTest "copilot-repository-settings-schema" (
      let
        failures = settings:
          map (assertion: assertion.message)
          (lib.filter (assertion: !assertion.assertion)
            (evalDevenv {
              ai.copilot = {
                enable = true;
                native.settings = settings;
              };
            })
            .config
            .assertions);
        rejects = key: settings: let
          messages = failures settings;
        in
          messages != [] && lib.all (message: lib.hasInfix "repository settings" message && lib.hasInfix key message) messages;
        valid = {
          autoTier = "balance";
          companyAnnouncements = ["Read CONTRIBUTING.md"];
          contextTier = "long_context";
          deniedUrls = ["https://example.invalid"];
          disableAllHooks = false;
          disabledMcpServers = ["probe"];
          disabledSkills = ["probe"];
          effortLevel = "high";
          enabledPlugins.probe = true;
          extraKnownMarketplaces.probe.source = {
            repo = "owner/repo";
            source = "github";
          };
          hooks.sessionStart = [];
          includeCoAuthoredBy = true;
          mergeStrategy = "rebase";
          model = "gpt-5";
          respectGitignore = true;
        };
      in
        failures valid
        == []
        && rejects "theme" {theme = "github";}
        && rejects "contextTier" {contextTier = "huge";}
        && rejects "respectGitignore" {respectGitignore = "yes";}
        && rejects "enabledPlugins" {enabledPlugins.probe = "yes";}
        && rejects "hooks" {hooks.sessionStart = "echo";}
        && rejects "effortLevel" {effortLevel = 5;}
        && hmSettings (evalHm {
          ai.copilot = {
            enable = true;
            native.settings.theme = "github";
          };
        })
        == {theme = "github";}
    );

    # Copilot resolves the repository settings path against the git root of
    # the directory it runs in (`gitFindRootWithOptionalWorktreeResolution`,
    # which answers a linked worktree's own top level). A devenv root below
    # the git root therefore writes a file Copilot never opens, so the
    # module warns, naming the option. Equal roots, and a project devenv
    # reports no git root for, stay silent.
    module-copilot-devenv-warns-below-git-root = mkTest "copilot-devenv-warns-below-git-root" (
      let
        warnings = extra:
          (evalDevenv ({
              ai.copilot = {
                enable = true;
                native.settings.model = "gpt-5";
              };
              devenv.root = "/repo/services/api";
            }
            // extra))
          .config
          .warnings;
        named = lib.any (warning: lib.hasInfix "ai.copilot.native.settings" warning && lib.hasInfix "/repo/services/api" warning);
      in
        named (warnings {git.root = "/repo";})
        && !named (warnings {git.root = "/repo/services/api";})
        && !named (warnings {git.root = null;})
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
        mcpFile = (deliveredFiles result.config).".copilot/mcp-config.json" or null;
        mcpValue = result.config.ai.copilot.files.".copilot/mcp-config.json".content.value;
      in
        mcpFile
        != null
        && mcpValue.mcpServers ? test-server
        && fromGeneratedTree ".copilot/mcp-config.json" mcpFile
        # `copilot mcp add` renames over this file, so it is a copy.
        && result.config.ai.copilot.files.".copilot/mcp-config.json".method == "copy-ro"
        && !(result.config.home.file ? ".copilot/mcp-config.json")
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

    # ── Copilot feature-gap closure ────────────────────────────────
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
        lspEntryOf "lspServers" ((deliveredFiles result.config).".copilot/lsp-config.json" or null) "typescript"
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
        lspEntryOf "lspServers" ((deliveredFiles result.config).".github/lsp.json" or null) "typescript"
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
    # file out from under the flag. Deriving the needle from the delivered
    # files closes that: both ends move together, and only a divergence fails.
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
          ''--additional-mcp-config @''${HOME}/${mcpConfigKeyOf name (deliveredFiles result.config)}''
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
      in
        fromGeneratedTree ".copilot/agents/reviewer.md" result.config.home.file.".copilot/agents/reviewer.md"
        && lib.hasInfix "Review code carefully" (markdownInput result ".copilot/agents/reviewer.md").text
    );

    module-copilot-devenv-writes-agent-files = mkTest "copilot-devenv-writes-agent-files" (
      let
        result = evalDevenv {
          ai.copilot = {
            enable = true;
            agents.reviewer = "# Reviewer\n\nReview code carefully.";
          };
        };
      in
        fromGeneratedTree ".github/agents/reviewer.agent.md" (deliveredFiles result.config).".github/agents/reviewer.agent.md"
        && lib.hasInfix "Review code carefully" (markdownInput result ".github/agents/reviewer.agent.md").text
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
      in
        fromGeneratedTree ".github/copilot-instructions.md" (deliveredFiles result.config).".github/copilot-instructions.md"
        && lib.hasInfix "Copilot devenv context" (markdownInput result ".github/copilot-instructions.md").text
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
        (lspEntryOf "lspServers" ((deliveredFiles result.config).".copilot/lsp-config.json" or null) "typescript").command or null
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
        (lspEntryOf "lspServers" ((deliveredFiles result.config).".github/lsp.json" or null) "typescript").command or null
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
        (lspEntryOf "lspServers" ((deliveredFiles result.config).".copilot/lsp-config.json" or null) "typescript").fileExtensions or null
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
        !(builtins.tryEval (deliveredFiles result.config).".copilot/lsp-config.json".text).success
    );

    # Copilot rejects the whole file when a server name holds anything but
    # ASCII letters, digits, `_` and `-`, and the name is the attribute key,
    # so a quoted "nix.lsp" must fail evaluation. The same config renamed to
    # "nix_lsp-1" must render: that is the positive control, and it pins
    # `_` and `-` as accepted.
    module-copilot-lsp-invalid-name-throws = mkTest "copilot-lsp-invalid-name-throws" (
      let
        evaluate = name:
          (evalHm {
            ai.copilot.enable = true;
            ai.lspServers.${name} = {
              command = "nixd";
              extensions = ["nix"];
            };
          }).config;
        fileFor = name: (deliveredFiles (evaluate name)).".copilot/lsp-config.json";
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
      in
        fromGeneratedTree ".copilot/agents/reviewer.md" result.config.home.file.".copilot/agents/reviewer.md"
        && lib.hasInfix "Reviewer" (markdownInput result ".copilot/agents/reviewer.md").text
    );

    module-copilot-hm-path-agent-resolves-to-text = mkTest "copilot-hm-path-agent-resolves-to-text" (
      let
        result = evalHm {
          ai.copilot.enable = true;
          ai.agents.reviewer = ../../claude-code/checks/fixtures/claude-agents/agent-one.md;
        };
      in
        fromGeneratedTree ".copilot/agents/reviewer.md" result.config.home.file.".copilot/agents/reviewer.md"
        && (markdownInput result ".copilot/agents/reviewer.md").text == builtins.readFile ../../claude-code/checks/fixtures/claude-agents/agent-one.md
    );

    # Devenv: top-level ai.agents fans out to Copilot's .github/agents.
    module-copilot-devenv-top-level-agents-fanout = mkTest "copilot-devenv-top-level-agents-fanout" (
      let
        result = evalDevenv {
          ai.copilot.enable = true;
          ai.agents.reviewer = "# Reviewer";
        };
      in
        fromGeneratedTree ".github/agents/reviewer.agent.md" (deliveredFiles result.config).".github/agents/reviewer.agent.md"
        && lib.hasInfix "Reviewer" (markdownInput result ".github/agents/reviewer.agent.md").text
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
        hm = evalHm config;
        devenv = evalDevenv config;
        delivered = evaluated: files: path: fromGeneratedTree path files.${path} && (markdownInput evaluated path).text == expected;
      in
        delivered hm hm.config.home.file ".copilot/agents/store-string.md"
        && delivered hm hm.config.home.file ".copilot/agents/agent-one.md"
        && delivered devenv devenv.config.files ".github/agents/store-string.agent.md"
        && delivered devenv devenv.config.files ".github/agents/agent-one.agent.md"
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
