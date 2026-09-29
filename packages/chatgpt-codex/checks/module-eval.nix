# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiBase aiStubs claudeSettings deliveredFiles evalDevenv evalDevenvWithGetEnv evalDevenvWithSpecialArgs evalHm fromGeneratedTree hasLiteral markdownInput mkTest mkWrapperGrepTest ownedDocument ownPlan tomlFormat windowNoticeLines;
  daemonSettings = evaluated:
    ownedDocument "codex" "${evaluated.config.ai.codex.configDir}/app-server-daemon/settings.json" evaluated;
  # Execpolicy rules are read-only copies on both backends, so their bytes are
  # in the copy writer's plan, keyed by file name, not in home.file / files.
  execpolicyTarget = evaluated:
    lib.head
    (ownPlan "codex" (
        if evaluated.config ? home
        then "materialize-codex-execpolicy-write"
        else "ai:codex:materialize-execpolicy"
      )
      evaluated)
    .targets;
  execpolicyUnits = evaluated: (execpolicyTarget evaluated).units;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) codexExtracted codexSettingsActivation hmCodexSettings withHmDaemonDefault;
in {
  checks = {
    # ── Codex package/factory enable vertical ───────────────────────
    module-codex-default-disabled = mkTest "codex-default-disabled" (
      let
        hm = evalHm {};
        devenv = evalDevenv {};
      in
        !hm.config.ai.codex.enable
        && !devenv.config.ai.codex.enable
        && hm.config.home.packages == []
        && devenv.config.packages == []
    );

    # The two backends legitimately install DIFFERENT derivations here. devenv's
    # launcher always passes `--no-daemon` (see mkCodex.nix), so enabling Codex
    # on devenv always produces a wrapper, whatever the environment pool holds.
    # The pool would force one too: devenv has no `programs.git`, so the
    # sandbox-safe Git SSH default rides Codex's launcher rather than being
    # exported into the project shell. Home Manager states that default in
    # Git's own config, so with nothing else to deliver the upstream package
    # ships untouched. The SSH VALUE is asserted by
    # `module-ai-git-ssh-default-follows-harnesses`; this one is about shape.
    module-codex-enabled-installs-package = mkTest "codex-enabled-installs-package" (
      let
        hm = evalHm {ai.codex.enable = true;};
        devenv = evalDevenv {ai.codex.enable = true;};
        expected = aiStubs.chatgpt-codex;
        devenvPackages = devenv.config.packages;
      in
        hm.config.home.packages
        == [expected]
        && builtins.length devenvPackages == 1
        && lib.hasSuffix "chatgpt-codex-wrapped" (
          builtins.baseNameOf (builtins.head devenvPackages)
        )
    );

    module-codex-default-sandbox-roots = mkTest "codex-default-sandbox-roots" (
      let
        settings = {
          ai.codex = {
            enable = true;
            native.settings.sandbox_mode = "workspace-write";
          };
        };
        hmRoots = (hmCodexSettings (evalHm settings)).sandbox_workspace_write.writable_roots;
        rootsWithEnvironment = environment:
          (evalDevenvWithGetEnv (name: environment.${name} or "") settings).config.ai.codex.files.".codex/config.toml".content.source.value.sandbox_workspace_write.writable_roots;
        devenvNoEnvironmentRoots = rootsWithEnvironment {};
        devenvHomeRoots = rootsWithEnvironment {HOME = "/home/test";};
        devenvXdgRoots = rootsWithEnvironment {
          HOME = "/home/ignored";
          XDG_CACHE_HOME = "/tmp/xdg-cache";
        };
      in
        hmRoots
        == ["/home/test/.cache/nix"]
        && devenvNoEnvironmentRoots == ["/tmp/devenv-root/.git"]
        && devenvHomeRoots
        == [
          "/tmp/devenv-root/.git"
          "/home/test/.cache/nix"
        ]
        && devenvXdgRoots
        == [
          "/tmp/devenv-root/.git"
          "/tmp/xdg-cache/nix"
        ]
    );

    module-codex-enabled-integration-sandbox-roots = mkTest "codex-enabled-integration-sandbox-roots" (
      let
        environment = {
          HOME = "/home/ignored";
          XDG_CACHE_HOME = "/tmp/xdg-cache";
        };
        evaluate = settings:
          (evalDevenvWithGetEnv (name: environment.${name} or "") settings).config.ai.codex.files.".codex/config.toml".content.source.value;
        legacy = evaluate {
          ai.codex = {
            enable = true;
            native.settings = {
              sandbox_mode = "workspace-write";
              sandbox_workspace_write.writable_roots = ["/tmp/xdg-cache/treefmt"];
            };
          };
          treefmt.enable = true;
        };
        named = evaluate {
          ai.codex = {
            enable = true;
            native.settings = {
              default_permissions = "project-edit";
              permissions.project-edit.extends = ":workspace";
            };
          };
          treefmt.enable = true;
        };
        disabled = evaluate {
          ai.codex = {
            enable = true;
            native.settings.sandbox_mode = "workspace-write";
          };
        };
        expectedIntegrationRoots = [
          "/tmp/xdg-cache/nix"
          "/tmp/xdg-cache/treefmt"
        ];
      in
        legacy.sandbox_workspace_write.writable_roots
        == ["/tmp/xdg-cache/treefmt" "/tmp/devenv-root/.git" "/tmp/xdg-cache/nix"]
        && builtins.all (root: named.permissions.project-edit.filesystem.${root} == "write") expectedIntegrationRoots
        && !(named.permissions.project-edit.filesystem ? "/tmp/devenv-root/.git")
        && !(builtins.elem "/tmp/xdg-cache/treefmt" disabled.sandbox_workspace_write.writable_roots)
    );

    module-codex-git-common-dir-permission = mkTest "codex-git-common-dir-permission" (
      let
        entries = [
          {
            path = "/repos/main/.git";
            type = "directory";
          }
          {
            path = "/repos/main/.git/HEAD";
            type = "regular";
          }
          {
            path = "/repos/main/.git/config";
            type = "regular";
          }
          {
            path = "/repos/main/.git/objects";
            type = "directory";
          }
          {
            content = "gitdir: ../main/.git/worktrees/sibling\n";
            path = "/repos/sibling/.git";
            type = "regular";
          }
          {
            path = "/repos/main/.git/worktrees/sibling";
            type = "directory";
          }
          {
            path = "/repos/main/.git/worktrees/sibling/HEAD";
            type = "regular";
          }
          {
            content = "../..\n";
            path = "/repos/main/.git/worktrees/sibling/commondir";
            type = "regular";
          }
          {
            content = "gitdir: /repos/main/.git/worktrees/arbitrary\n";
            path = "/scratch/agent/.git";
            type = "regular";
          }
          {
            path = "/repos/main/.git/worktrees/arbitrary";
            type = "directory";
          }
          {
            path = "/repos/main/.git/worktrees/arbitrary/HEAD";
            type = "regular";
          }
          {
            content = "/repos/main/.git\n";
            path = "/repos/main/.git/worktrees/arbitrary/commondir";
            type = "regular";
          }
          {
            path = "/repos/separate/.git";
            type = "directory";
          }
          {
            path = "/repos/separate/.git/HEAD";
            type = "regular";
          }
          {
            content = "../shared-git\n";
            path = "/repos/separate/.git/commondir";
            type = "regular";
          }
          {
            path = "/repos/separate/shared-git";
            type = "directory";
          }
          {
            path = "/repos/separate/shared-git/config";
            type = "regular";
          }
          {
            path = "/repos/separate/shared-git/objects";
            type = "directory";
          }
          {
            content = "not a gitdir pointer\n";
            path = "/repos/malformed/.git";
            type = "regular";
          }
          {
            content = "gitdir: /\n";
            path = "/repos/unsafe/.git";
            type = "regular";
          }
          {
            path = "/";
            type = "directory";
          }
        ];
        filesystem = lib.listToAttrs (map (entry: lib.nameValuePair entry.path (removeAttrs entry ["path"])) entries);
        resolver = import ../lib/resolveGitCommonDir.nix {
          inherit lib;
          pathExists = path: builtins.hasAttr path filesystem;
          readFile = path: filesystem.${path}.content;
          readFileType = path: filesystem.${path}.type;
        };
        evaluate = root: settings:
          (evalDevenvWithSpecialArgs {
              codexGetEnv = _: "";
              codexGitCommonDirResolver = resolver;
            } {
              ai.codex = {
                enable = true;
                native.settings = settings;
              };
              devenv.root = root;
              git.root = root;
            }).config.ai.codex.files.".codex/config.toml".content.source.value;
        namedSettings = {
          default_permissions = "project-edit";
          permissions.project-edit.extends = ":workspace";
        };
        primary = evaluate "/repos/main" namedSettings;
        sibling = evaluate "/repos/sibling" namedSettings;
        arbitrary = evaluate "/scratch/agent" namedSettings;
        directoryCommon = evaluate "/repos/separate" namedSettings;
        nonGit = evaluate "/repos/plain" namedSettings;
        legacy = evaluate "/repos/sibling" {sandbox_mode = "workspace-write";};
        denied = evaluate "/repos/sibling" (lib.recursiveUpdate namedSettings {
          permissions.project-edit.filesystem."/repos/main/.git" = "deny";
        });
        primaryFilesystem = primary.permissions.project-edit.filesystem;
        siblingFilesystem = sibling.permissions.project-edit.filesystem;
        arbitraryFilesystem = arbitrary.permissions.project-edit.filesystem;
        malformed = builtins.tryEval (evaluate "/repos/malformed" namedSettings);
        unsafe = builtins.tryEval (evaluate "/repos/unsafe" namedSettings);
      in
        primaryFilesystem."/repos/main/.git"
        == "write"
        && siblingFilesystem."/repos/main/.git" == "write"
        && arbitraryFilesystem."/repos/main/.git" == "write"
        && directoryCommon.permissions.project-edit.filesystem."/repos/separate/shared-git" == "write"
        && !(siblingFilesystem ? "/repos/sibling/.git")
        && !(siblingFilesystem ? "/repos/main/.git/worktrees/sibling")
        && !(siblingFilesystem ? "/repos/main/.git/.git")
        && !(nonGit.permissions.project-edit ? filesystem)
        && legacy.sandbox_workspace_write.writable_roots == ["/repos/sibling/.git"]
        && denied.permissions.project-edit.filesystem."/repos/main/.git" == "deny"
        && !malformed.success
        && !unsafe.success
    );

    module-codex-default-getenv-needs-no-module-arg = mkTest "codex-default-getenv-needs-no-module-arg" (
      let
        roots =
          (evalDevenv {
            ai.codex = {
              enable = true;
              native.settings.sandbox_mode = "workspace-write";
            };
          }).config.ai.codex.files.".codex/config.toml".content.source.value.sandbox_workspace_write.writable_roots;
      in
        builtins.deepSeq roots (builtins.elem "/tmp/devenv-root/.git" roots)
    );

    module-codex-skills-disabled-emits-nothing = mkTest "codex-skills-disabled-emits-nothing" (
      let
        config.ai.codex.skills.example = ../../claude-code/checks/fixtures/claude-skills/skill-a;
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        !(hm.config.home.file ? ".agents/skills/example")
        && !(devenv.config.files ? ".agents/skills/example")
    );

    module-codex-skills-fanout = mkTest "codex-skills-fanout" (
      let
        config.ai = {
          codex = {
            enable = true;
            skills.local = ../../claude-code/checks/fixtures/claude-skills/skill-b;
          };
          skills.shared = ../../claude-code/checks/fixtures/claude-skills/skill-a;
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        hm.config.home.file.".agents/skills/local".source
        == ../../claude-code/checks/fixtures/claude-skills/skill-b
        && !(hm.config.home.file.".agents/skills/local" ? recursive)
        && hm.config.home.file.".agents/skills/shared".source
        == ../../claude-code/checks/fixtures/claude-skills/skill-a
        && !(hm.config.home.file.".agents/skills/shared" ? recursive)
        && devenv.config.files.".agents/skills/local".source
        == ../../claude-code/checks/fixtures/claude-skills/skill-b
        && devenv.config.files.".agents/skills/shared".source
        == ../../claude-code/checks/fixtures/claude-skills/skill-a
        && hm.config.home.activation ? codexMigrateSkillLinks
        # It moves user directories, so under DRY_RUN it must only echo.
        && lib.hasInfix "run /nix/store/" hm.config.home.activation.codexMigrateSkillLinks.text
        && !lib.hasInfix "run /nix/store/" devenv.config.tasks."ai:codex:migrate-skill-links".exec
        && devenv.config.tasks ? "ai:codex:migrate-skill-links"
        && devenv.config.tasks."ai:codex:migrate-skill-links".after
        == ["devenv:files:cleanup"]
        && lib.elem "devenv:files" devenv.config.tasks."ai:codex:migrate-skill-links".before
    );

    module-codex-skillsdir-fanout = mkTest "codex-skillsdir-fanout" (
      let
        config.ai.codex = {
          enable = true;
          skillsDir = ../../claude-code/checks/fixtures/claude-skills;
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        hm.config.home.file ? ".agents/skills/skill-a"
        && hm.config.home.file ? ".agents/skills/skill-b"
        && devenv.config.files ? ".agents/skills/skill-a"
        && devenv.config.files ? ".agents/skills/skill-b"
    );

    module-codex-single-file-skill-wraps-directory = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          skills.single = ../../claude-code/checks/fixtures/claude-skills/skill-a/SKILL.md;
        };
      };
      source = evaluated.config.home.file.".agents/skills/single".source;
    in
      pkgs.runCommand "module-test-codex-single-file-skill-wraps-directory" {} ''
        test -d ${source}
        test -f ${source}/SKILL.md
        cmp ${../../claude-code/checks/fixtures/claude-skills/skill-a/SKILL.md} ${source}/SKILL.md
        touch "$out"
      '';

    module-codex-unsafe-skill-name-fails = mkTest "codex-unsafe-skill-name-fails" (
      let
        config.ai.codex = {
          enable = true;
          skills."../escape" = ../../claude-code/checks/fixtures/claude-skills/skill-a;
        };
        failsSafely = evaluated:
          builtins.any (assertion:
            !assertion.assertion
            && lib.hasInfix "single safe path components" assertion.message)
          evaluated.config.assertions;
      in
        failsSafely (evalHm config)
        && failsSafely (evalDevenv config)
    );

    module-codex-skill-runtime-replaces-root = mkTest "codex-skill-runtime-replaces-root" (
      let
        evaluated = evalHm {
          ai = {
            codex = {
              enable = true;
              skills.duplicate = ../../claude-code/checks/fixtures/claude-skills/skill-b;
            };
            skills.duplicate = ../../claude-code/checks/fixtures/claude-skills/skill-a;
          };
        };
      in
        evaluated.config.home.file.".agents/skills/duplicate".source
        == ../../claude-code/checks/fixtures/claude-skills/skill-b
    );

    module-codex-default-model-effort-parity = mkTest "codex-default-model-effort-parity" (
      let
        hm = evalHm {ai.codex.enable = true;};
        devenv = evalDevenv {ai.codex.enable = true;};
        expected = {
          model = "gpt-6-astra";
          model_reasoning_effort = "xhigh";
        };
      in
        hmCodexSettings hm
        == withHmDaemonDefault expected
        && devenv.config.ai.codex.files.".codex/config.toml".content.source.value == expected
    );

    module-codex-empty-settings-emits-no-toml = mkTest "codex-empty-settings-emits-no-toml" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            # Null beats Home Manager's mkDefault, as it does every default.
            features.daemon_auto_start = null;
            model = null;
            model_reasoning_effort = null;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        !(hm.config.home.file ? ".codex/config.toml")
        && hmCodexSettings hm == {}
        && !(hm.config.home.file ? ".codex/hooks.json")
        && !(devenv.config.files ? ".codex/config.toml")
        && !(devenv.config.files ? ".codex/hooks.json")
    );

    # ── Permission models ───────────────────────────────────────────────────
    # `[permissions.<name>]` tables are ordinary mergeable Codex config and are
    # supported. The distinct whole-file `--profile` surface (`ai.codex.profiles`)
    # was removed 2026-09-19 as unreachable dead code — see the reservation
    # comment in `packages/chatgpt-codex/lib/mkCodex.nix`.
    module-codex-default-permissions-enabled = mkTest "codex-default-permissions-enabled" (
      let
        config.ai.codex = {
          enable = true;
          native.settings.default_permissions = ":workspace";
        };
        passes = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
      in
        passes (evalHm config) && passes (evalDevenv config)
    );

    module-codex-permissions-enabled = mkTest "codex-permissions-enabled" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            default_permissions = "project-edit";
            permissions.project-edit.extends = ":workspace";
          };
        };
        passes = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
      in
        passes (evalHm config) && passes (evalDevenv config)
    );

    module-codex-mcp-lowering-parity = mkTest "codex-mcp-lowering-parity" (
      let
        config.ai = {
          codex.enable = true;
          mcpServers = {
            docs = {
              command = "/bin/docs";
              args = ["serve"];
              codex = {
                command = "must-not-clobber-base";
                defaultToolsApprovalMode = "prompt";
                disabledTools = ["delete"];
                enabled = true;
                required = true;
                startupTimeoutSec = 15;
                tools.search.approvalMode = "auto";
              };
            };
            remote = {
              url = "https://example.test/mcp";
              codex = {
                bearerTokenEnvVar = "MCP_TOKEN";
                envHttpHeaders.X-Tenant = "MCP_TENANT";
                toolTimeoutSec = 90;
              };
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = {
          docs = {
            args = ["serve"];
            command = "/bin/docs";
            default_tools_approval_mode = "prompt";
            disabled_tools = ["delete"];
            enabled = true;
            required = true;
            startup_timeout_sec = 15;
            tools.search.approval_mode = "auto";
          };
          remote = {
            bearer_token_env_var = "MCP_TOKEN";
            env_http_headers.X-Tenant = "MCP_TENANT";
            tool_timeout_sec = 90;
            url = "https://example.test/mcp";
          };
        };
      in
        (hmCodexSettings hm).mcp_servers
        == expected
        && devenv.config.ai.codex.files.".codex/config.toml".content.source.value.mcp_servers == expected
    );

    module-codex-mcp-freeform-rejects-non-toml = mkTest "codex-mcp-freeform-rejects-non-toml" (
      let
        hm = evalHm {
          ai.codex = {
            enable = true;
            mcpServers.docs = {
              command = "/bin/docs";
              codex.future = value: value;
            };
          };
        };
        evaluated = builtins.tryEval (hmCodexSettings hm);
      in
        !evaluated.success
    );

    module-codex-mcp-credential-wrapper-parity = mkTest "codex-mcp-credential-wrapper-parity" (
      let
        config.ai = {
          codex.enable = true;
          mcpServers.context7-mcp = {
            package = pkgs.hello;
            settings.credentials.file = "/run/secrets/context7-api-key";
          };
        };
        hmServer = (hmCodexSettings (evalHm config)).mcp_servers.context7-mcp;
        devenvServer = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.source.value.mcp_servers.context7-mcp;
        rendered = builtins.toJSON hmServer;
      in
        hmServer
        == devenvServer
        && lib.hasInfix "context7-mcp-env" hmServer.command
        && lib.take 2 hmServer.args == ["--transport" "stdio"]
        && !(lib.hasInfix "/run/secrets/context7-api-key" rendered)
        && !(hmServer ? type)
    );

    # Exercise every supported MCP lowering shape together: two HTTP services,
    # three typed package servers (including two credential wrappers), and one
    # raw stdio server must coexist in Codex's native table. Keep this rationale
    # self-contained; private implementation handoffs are intentionally
    # disposable and must never become the only explanation for a durable gate.
    module-codex-mcp-downstream-pool-compatible = mkTest "codex-mcp-downstream-pool-compatible" (
      let
        config.ai = {
          codex.enable = true;
          mcpServers = {
            context7-mcp = {
              package = pkgs.hello;
              settings.credentials.file = "/run/secrets/context7-api-key";
            };
            effect-mcp.url = "http://127.0.0.1:19760/mcp";
            git-mcp.package = pkgs.hello;
            github-mcp = {
              package = pkgs.hello;
              settings.credentials.file = "/run/secrets/github-token";
            };
            nixos-mcp.url = "http://127.0.0.1:19761/mcp";
            openmemory = {
              command = "/bin/openmemory";
              args = ["mcp"];
            };
          };
        };
        hmServers = (hmCodexSettings (evalHm config)).mcp_servers;
        devenvServers = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.source.value.mcp_servers;
      in
        hmServers
        == devenvServers
        && builtins.attrNames hmServers
        == [
          "context7-mcp"
          "effect-mcp"
          "git-mcp"
          "github-mcp"
          "nixos-mcp"
          "openmemory"
        ]
        && lib.hasInfix "context7-mcp-env" hmServers.context7-mcp.command
        && lib.hasInfix "github-mcp-env" hmServers.github-mcp.command
        && hmServers.effect-mcp.url == "http://127.0.0.1:19760/mcp"
        && hmServers.openmemory.command == "/bin/openmemory"
    );

    module-codex-mcp-native-table-collision-fails = mkTest "codex-mcp-native-table-collision-fails" (
      let
        evaluated = evalHm {
          ai = {
            codex = {
              enable = true;
              native.settings.mcp_servers.native.command = "native";
            };
            mcpServers.shared.command = "shared";
          };
        };
      in
        builtins.any (assertion: !assertion.assertion && lib.hasInfix "native.settings.mcp_servers" assertion.message) evaluated.config.assertions
    );

    module-codex-settings-rendering-parity = mkTest "codex-settings-rendering-parity" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            features = {
              memories = true;
              speculative_future_flag = false;
            };
            model = "custom-provider/model";
            model_reasoning_effort = "ultra";
            model_verbosity = "low";
            personality = "pragmatic";
            web_search = "indexed";
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = {
          features = {
            memories = true;
            speculative_future_flag = false;
          };
          model = "custom-provider/model";
          model_reasoning_effort = "ultra";
          model_verbosity = "low";
          personality = "pragmatic";
          web_search = "indexed";
        };
        devenvSource = devenv.config.ai.codex.files.".codex/config.toml".content.source;
      in
        hmCodexSettings hm
        == withHmDaemonDefault expected
        && devenvSource.value == expected
    );

    # This is a real activation lifecycle test, not merely an eval-shape check.
    # Codex persists ad-hoc trust and native feature/MCP edits in user
    # config.toml, so regressions here otherwise surface only when the TUI tries
    # config/batchWrite against an immutable Nix store symlink.
    module-codex-settings-reconciliation = let
      activationV1 = codexSettingsActivation {
        ai.codex = {
          enable = true;
          native.settings = {
            features.memories = true;
            future_array = [
              {
                enabled = true;
                name = "one";
              }
            ];
            mcp_servers.managed.command = "/bin/managed-v1";
            model = "nix-model-v1";
            shape = "scalar-v1";
          };
        };
      };
      activationV2 = codexSettingsActivation {
        ai.codex = {
          enable = true;
          native.settings = {
            model = "nix-model-v2";
            sandbox_mode = "read-only";
            shape.child = "table-v2";
          };
        };
      };
      activationEmpty = codexSettingsActivation {
        ai.codex = {
          enable = true;
          native.settings = {
            # Null beats Home Manager's mkDefault, so this retracts that leaf.
            features.daemon_auto_start = null;
            model = null;
            model_reasoning_effort = null;
          };
        };
      };
      activationMalformed = codexSettingsActivation {
        ai.codex = {
          configDir = ".codex-malformed";
          enable = true;
          native.settings.model = "must-not-land";
        };
      };
      activationBadManifest = codexSettingsActivation {
        ai.codex = {
          configDir = ".codex-bad-manifest";
          enable = true;
          native.settings.model = "manifest-guard";
        };
      };
    in
      pkgs.runCommand "module-test-codex-settings-reconciliation" {} ''
        export HOME="$PWD/home"
        export XDG_STATE_HOME="$PWD/state"
        # The activation* fragments below are HM activation entry text, which
        # expects home-manager's `run` helper (lib/bash/home-manager.sh) already in
        # scope.
        ${harness.hmRunShim}
        ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex"

        # Model the old HM delivery exactly: config.toml is a read-only symlink
        # into immutable content. The first reconciliation must replace the link
        # itself, never follow it and attempt to mutate its target.
        ${pkgs.coreutils}/bin/cat > static-config.toml <<'EOF'
        # native comment survives
        retired_before_json_backend = true
        model = "runtime-model"

        [features]
        native_runtime = true

        [projects."/home/test/ad-hoc"]
        trust_level = "trusted"
        EOF
        ${pkgs.coreutils}/bin/chmod 444 static-config.toml
        ${pkgs.coreutils}/bin/ln -s "$PWD/static-config.toml" "$HOME/.codex/config.toml"

        # A ledger from the TOML-only helper must still be read at exactly its
        # historical path after JSON support is added to the shared helper.
        legacy_manifest="$XDG_STATE_HOME/nix-agentic-tools/toml-settings/codex-config-${builtins.hashString "sha256" ".codex/config.toml"}.json"
        mkdir -p "$(dirname "$legacy_manifest")"
        printf '%s\n' '{"managed_paths":[["retired_before_json_backend"]],"version":1}' > "$legacy_manifest"
        chmod 600 "$legacy_manifest"

        ${activationV1}

        test -f "$HOME/.codex/config.toml"
        test ! -L "$HOME/.codex/config.toml"
        test "$(${pkgs.coreutils}/bin/stat -c %a "$HOME/.codex/config.toml")" = 600
        ${pkgs.gnugrep}/bin/grep -Fq '# native comment survives' "$HOME/.codex/config.toml"
        ${pkgs.python3}/bin/python - "$HOME/.codex/config.toml" <<'PY'
        import sys
        import tomllib

        with open(sys.argv[1], "rb") as handle:
            config = tomllib.load(handle)

        assert config["future_array"] == [{"enabled": True, "name": "one"}]
        assert config["shape"] == "scalar-v1"
        assert "retired_before_json_backend" not in config
        PY

        # Simulate native writers after activation. These siblings share tables
        # with Nix-owned leaves and therefore catch a too-coarse table manifest.
        ${pkgs.coreutils}/bin/cat >> "$HOME/.codex/config.toml" <<'EOF'

        [mcp_servers.native]
        command = "/bin/native"
        EOF

        ${activationV2}

        test "$(${pkgs.coreutils}/bin/stat -c %a "$HOME/.codex/config.toml")" = 600
        ${pkgs.python3}/bin/python - "$HOME/.codex/config.toml" <<'PY'
        import sys
        import tomllib

        with open(sys.argv[1], "rb") as handle:
            config = tomllib.load(handle)

        assert config["model"] == "nix-model-v2"
        assert config["sandbox_mode"] == "read-only"
        assert config["projects"]["/home/test/ad-hoc"]["trust_level"] == "trusted"
        assert config["features"] == {"daemon_auto_start": False, "native_runtime": True}
        assert "future_array" not in config
        assert config["mcp_servers"] == {"native": {"command": "/bin/native"}}
        assert config["shape"] == {"child": "table-v2"}
        PY

        manifest="$(${pkgs.findutils}/bin/find "$XDG_STATE_HOME" -name '*.json' -type f -print)"
        test "$manifest" = "$legacy_manifest"
        test "$(${pkgs.coreutils}/bin/stat -c %a "$manifest")" = 600
        test "$(${pkgs.coreutils}/bin/stat -c %a "$(${pkgs.coreutils}/bin/dirname "$manifest")")" = 700

        # Identical activation is byte- and metadata-idempotent. Pinning mtimes
        # before the second run detects an implementation that rewrites equal
        # content through a fresh temp file on every Home Manager activation.
        ${pkgs.coreutils}/bin/touch -d @1000000000 "$HOME/.codex/config.toml" "$manifest"
        config_mtime="$(${pkgs.coreutils}/bin/stat -c %Y "$HOME/.codex/config.toml")"
        manifest_mtime="$(${pkgs.coreutils}/bin/stat -c %Y "$manifest")"
        ${activationV2}
        test "$(${pkgs.coreutils}/bin/stat -c %Y "$HOME/.codex/config.toml")" = "$config_mtime"
        test "$(${pkgs.coreutils}/bin/stat -c %Y "$manifest")" = "$manifest_mtime"

        # Empty settings still run once to retire prior Nix leaves. Native state
        # remains and the now-empty ownership manifest disappears.
        ${activationEmpty}
        ${pkgs.python3}/bin/python - "$HOME/.codex/config.toml" <<'PY'
        import sys
        import tomllib

        with open(sys.argv[1], "rb") as handle:
            config = tomllib.load(handle)

        assert "model" not in config
        assert "sandbox_mode" not in config
        assert "shape" not in config
        assert config["projects"]["/home/test/ad-hoc"]["trust_level"] == "trusted"
        assert config["features"] == {"native_runtime": True}
        assert config["mcp_servers"] == {"native": {"command": "/bin/native"}}
        PY
        test ! -e "$manifest"

        # With no prior ownership ledger, empty desired settings are a true no-op
        # and must not create or parse an externally managed config.
        export HOME="$PWD/empty-home"
        export XDG_STATE_HOME="$PWD/empty-state"
        ${activationEmpty}
        test ! -e "$HOME/.codex/config.toml"
        test ! -e "$XDG_STATE_HOME"

        # Malformed native TOML aborts before either config or ownership state is
        # changed. Silent replacement would destroy exactly the state this path
        # exists to preserve.
        export HOME="$PWD/malformed-home"
        export XDG_STATE_HOME="$PWD/malformed-state"
        ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex-malformed"
        printf '%s\n' '[broken' > "$HOME/.codex-malformed/config.toml"
        before="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-malformed/config.toml")"
        if ${activationMalformed}
        then
          echo "malformed TOML reconciliation unexpectedly succeeded" >&2
          false
        fi
        after="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-malformed/config.toml")"
        test "$before" = "$after"
        test ! -e "$XDG_STATE_HOME"

        # The ownership ledger is authority for deletion, so corruption there is
        # also fail-closed. Guessing or discarding it could preserve stale Nix
        # policy or misclassify a native key as safe to remove.
        export HOME="$PWD/bad-manifest-home"
        export XDG_STATE_HOME="$PWD/bad-manifest-state"
        ${activationBadManifest}
        bad_manifest="$(${pkgs.findutils}/bin/find "$XDG_STATE_HOME" -name '*.json' -type f -print)"
        printf '%s\n' '{' > "$bad_manifest"
        before="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-bad-manifest/config.toml")"
        if ${activationBadManifest}
        then
          echo "malformed ownership manifest unexpectedly succeeded" >&2
          false
        fi
        after="$(${pkgs.coreutils}/bin/sha256sum "$HOME/.codex-bad-manifest/config.toml")"
        test "$before" = "$after"

        touch "$out"
      '';

    module-codex-security-settings-parity = mkTest "codex-security-settings-parity" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            allow_login_shell = false;
            approval_policy.granular = {
              mcp_elicitations = true;
              request_permissions = false;
              rules = true;
              sandbox_approval = true;
              skill_approval = false;
            };
            approvals_reviewer = "user";
            sandbox_mode = "workspace-write";
            sandbox_workspace_write = {
              exclude_slash_tmp = true;
              exclude_tmpdir_env_var = true;
              network_access = false;
              writable_roots = ["/var/lib/project-cache"];
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmSettings = hmCodexSettings hm;
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.source.value;
        withoutBackendRoots = settings:
          settings
          // {
            sandbox_workspace_write = removeAttrs settings.sandbox_workspace_write ["writable_roots"];
          };
      in
        withoutBackendRoots hmSettings
        == withHmDaemonDefault (withoutBackendRoots devenvSettings)
        && hmSettings.approval_policy.granular.rules
        && !hmSettings.approval_policy.granular.request_permissions
        && hmSettings.sandbox_mode == "workspace-write"
        && builtins.all
        (root: builtins.elem root hmSettings.sandbox_workspace_write.writable_roots)
        ["/var/lib/project-cache" "/home/test/.cache/nix"]
        && builtins.all
        (root: builtins.elem root devenvSettings.sandbox_workspace_write.writable_roots)
        ["/var/lib/project-cache" "/tmp/devenv-root/.git"]
    );

    module-codex-security-toml-syntax = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          native.settings = {
            approval_policy.granular = {
              request_permissions = false;
              sandbox_approval = true;
            };
            projects."/home/test/project".trust_level = "trusted";
            sandbox_mode = "workspace-write";
            sandbox_workspace_write.network_access = false;
          };
        };
      };
      source = tomlFormat.generate "codex-security-settings.toml" (hmCodexSettings evaluated);
    in
      pkgs.runCommand "module-test-codex-security-toml-syntax" {} ''
        ${pkgs.gnugrep}/bin/grep -Fqx '[approval_policy.granular]' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx 'request_permissions = false' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '[projects."/home/test/project"]' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx 'trust_level = "trusted"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '[sandbox_workspace_write]' ${source}
        touch "$out"
      '';

    module-codex-security-models-do-not-compose = mkTest "codex-security-models-do-not-compose" (
      let
        check = evaluated:
          builtins.any (assertion:
            !assertion.assertion
            && lib.hasInfix "default_permissions/permissions" assertion.message)
          evaluated.config.assertions;
        config.ai.codex = {
          enable = true;
          native.settings = {
            default_permissions = ":workspace";
            sandbox_mode = "workspace-write";
          };
        };
      in
        check (evalHm config)
        && check (evalDevenv config)
    );

    module-codex-security-empty-profile-model-does-not-conflict = mkTest "codex-security-empty-profile-model-does-not-conflict" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            permissions = {};
            sandbox_mode = "read-only";
          };
        };
        assertionsPass = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
      in
        assertionsPass (evalHm config)
        && assertionsPass (evalDevenv config)
    );

    module-codex-permission-profiles-parity = mkTest "codex-permission-profiles-parity" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            default_permissions = "project-edit";
            permissions.project-edit = {
              description = "Project editing with API access.";
              extends = ":workspace";
              filesystem = {
                ":minimal" = "read";
                ":workspace_roots" = {
                  "**/*.env" = "deny";
                  "." = "write";
                };
                glob_scan_max_depth = 8;
              };
              network = {
                domains = {
                  "*.github.com" = "allow";
                  "tracking.example.com" = "deny";
                };
                enabled = true;
                mode = "limited";
                unix_sockets."/var/run/docker.sock" = "allow";
              };
              workspace_roots."/home/test/project" = true;
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenvWithGetEnv (name: {HOME = "/home/test";}.${name} or "") config;
        hmSettings = hmCodexSettings hm;
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.source.value;
        withoutBackendRoots = settings:
          settings
          // {
            permissions.project-edit =
              settings.permissions.project-edit
              // {
                filesystem = removeAttrs settings.permissions.project-edit.filesystem [
                  "/home/test/.cache/nix"
                  "/tmp/devenv-root/.git"
                ];
              };
          };
      in
        withoutBackendRoots hmSettings
        == withHmDaemonDefault (withoutBackendRoots devenvSettings)
        && hmSettings.default_permissions == "project-edit"
        && hmSettings.permissions.project-edit.filesystem.":minimal" == "read"
        && hmSettings.permissions.project-edit.filesystem.":workspace_roots"."**/*.env" == "deny"
        && hmSettings.permissions.project-edit.network.domains."*.github.com" == "allow"
        && hmSettings.permissions.project-edit.filesystem."/home/test/.cache/nix" == "write"
        && !(devenvSettings.permissions.project-edit.filesystem ? "/tmp/devenv-root/.git")
        && builtins.all (assertion: assertion.assertion) hm.config.assertions
        && builtins.all (assertion: assertion.assertion) devenv.config.assertions
    );

    module-codex-permission-profile-layer-composition = mkTest "codex-permission-profile-layer-composition" (
      let
        user = evalHm {
          ai.codex = {
            enable = true;
            native.settings = {
              default_permissions = "project-edit";
              permissions.project-edit = {
                extends = ":workspace";
                filesystem."/tmp/shared" = "deny";
                network.enabled = true;
              };
            };
          };
        };
        project = evalDevenv {
          ai.codex = {
            enable = true;
            native.settings = {
              default_permissions = "project-edit";
              permissions.project-edit.filesystem = {
                "/tmp/project-cache" = "write";
                "/tmp/shared" = "write";
              };
            };
          };
        };
        userSettings = hmCodexSettings user;
        projectSettings = project.config.ai.codex.files.".codex/config.toml".content.source.value;
        # Codex merges same-named permission tables by key and gives the project
        # file higher precedence. Model that documented artifact composition
        # explicitly instead of comparing two independent full configurations.
        composedProfile = lib.recursiveUpdate userSettings.permissions.project-edit projectSettings.permissions.project-edit;
      in
        userSettings.default_permissions
        == "project-edit"
        && projectSettings.default_permissions == "project-edit"
        && composedProfile.extends == ":workspace"
        && composedProfile.network.enabled
        && composedProfile.filesystem."/home/test/.cache/nix" == "write"
        && composedProfile.filesystem."/tmp/project-cache" == "write"
        && composedProfile.filesystem."/tmp/shared" == "write"
        && builtins.all (assertion: assertion.assertion) user.config.assertions
        && builtins.all (assertion: assertion.assertion) project.config.assertions
    );

    module-codex-permission-profiles-toml-syntax = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          native.settings = {
            default_permissions = "project-edit";
            permissions.project-edit = {
              extends = ":workspace";
              filesystem.":workspace_roots" = {
                "**/*.env" = "deny";
                "." = "write";
              };
              network = {
                domains."api.openai.com" = "allow";
                enabled = true;
              };
            };
          };
        };
      };
      source = tomlFormat.generate "codex-permission-profiles.toml" (hmCodexSettings evaluated);
    in
      pkgs.runCommand "module-test-codex-permission-profiles-toml-syntax" {} ''
        ${pkgs.gnugrep}/bin/grep -Fqx 'default_permissions = "project-edit"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '[permissions.project-edit.filesystem.":workspace_roots"]' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '"**/*.env" = "deny"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '[permissions.project-edit.network.domains]' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '"api.openai.com" = "allow"' ${source}
        touch "$out"
      '';

    module-codex-execpolicy-directory-source-is-rejected = mkTest "codex-execpolicy-directory-source-is-rejected" (
      let
        config.ai.codex = {
          enable = true;
          execpolicyRules.directory = ../../../checks/fixtures;
        };
        rejects = evaluated:
          builtins.any (assertion:
            !assertion.assertion
            && lib.hasInfix "path sources" assertion.message)
          evaluated.config.assertions;
      in
        rejects (evalHm config)
        && rejects (evalDevenv config)
    );

    module-codex-execpolicy-missing-source-is-rejected = mkTest "codex-execpolicy-missing-source-is-rejected" (
      let
        config.ai.codex = {
          enable = true;
          execpolicyRules.missing = "/definitely/missing/codex.rules";
        };
        rejects = evaluated:
          builtins.any (assertion:
            !assertion.assertion
            && lib.hasInfix "path sources" assertion.message)
          evaluated.config.assertions;
      in
        rejects (evalHm config)
        && rejects (evalDevenv config)
    );

    module-codex-execpolicy-parity = mkTest "codex-execpolicy-parity" (
      let
        config.ai.codex = {
          enable = true;
          execpolicyRules.git-read = ''
            prefix_rule(
                pattern = ["git", ["diff", "log", "show"]],
                decision = "allow",
            )
          '';
        };
        hmRule = (execpolicyUnits (evalHm config))."git-read.rules".text;
        devenvRule = (execpolicyUnits (evalDevenv config))."git-read.rules".text;
      in
        hmRule
        == devenvRule
        && lib.hasInfix ''decision = "allow"'' hmRule
    );

    module-codex-execpolicy-runs-native-checker = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          execpolicyRules.git-read = ''
            prefix_rule(
                pattern = ["git", ["diff", "log", "show"]],
                decision = "allow",
                match = ["git show HEAD"],
                not_match = ["git status"],
            )
          '';
        };
      };
      rule = pkgs.writeText "git-read.rules" (execpolicyUnits evaluated)."git-read.rules".text;
    in
      pkgs.runCommand "module-test-codex-execpolicy-runs-native-checker" {} ''
        ${pkgs.ai.chatgpt-codex}/bin/codex execpolicy check --pretty \
          --rules ${rule} \
          -- git show HEAD > result.json
        ${pkgs.gnugrep}/bin/grep -Fq '"decision": "allow"' result.json
        touch "$out"
      '';

    module-codex-execpolicy-separate-from-markdown-rules = mkTest "codex-execpolicy-separate-from-markdown-rules" (
      let
        evaluated = evalHm {
          ai.codex = {
            enable = true;
            execpolicyRules.command-policy = ''prefix_rule(pattern = ["git", "status"])'';
            rules.command-guidance.text = "Explain every command before running it.";
          };
        };
        agentsMd = (markdownInput evaluated ".codex/AGENTS.md").text;
        execpolicy = (execpolicyUnits evaluated)."command-policy.rules".text;
      in
        lib.hasInfix "Explain every command" agentsMd
        && !lib.hasInfix "prefix_rule" agentsMd
        && lib.hasInfix "prefix_rule" execpolicy
    );

    module-codex-execpolicy-string-store-path-is-source = mkTest "codex-execpolicy-string-store-path-is-source" (
      let
        rule = pkgs.writeText "string-source.rules" ''prefix_rule(pattern = ["git", "status"])'';
        config.ai.codex = {
          enable = true;
          execpolicyRules.string-source = "${rule}";
        };
        hmSource = (execpolicyUnits (evalHm config))."string-source.rules".store;
        devenvSource = (execpolicyUnits (evalDevenv config))."string-source.rules".store;
      in
        hmSource
        == "${rule}"
        && devenvSource == "${rule}"
    );

    module-codex-execpolicy-symlinked-file-is-source = mkTest "codex-execpolicy-symlinked-file-is-source" (
      let
        rule = pkgs.writeText "symlink-target.rules" ''prefix_rule(pattern = ["git", "status"])'';
        symlink = pkgs.runCommand "symlink-source.rules" {} ''
          ln -s ${rule} "$out"
        '';
        config.ai.codex = {
          enable = true;
          execpolicyRules.symlink-source = "${symlink}";
        };
        hmSource = (execpolicyUnits (evalHm config))."symlink-source.rules".store;
        devenvSource = (execpolicyUnits (evalDevenv config))."symlink-source.rules".store;
      in
        hmSource
        == "${symlink}"
        && devenvSource == "${symlink}"
    );

    module-codex-execpolicy-user-default-is-reserved = mkTest "codex-execpolicy-user-default-is-reserved" (
      let
        config.ai.codex = {
          enable = true;
          execpolicyRules.default = ''prefix_rule(pattern = ["git", "status"])'';
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmFailure = lib.findFirst (assertion: !assertion.assertion) null hm.config.assertions;
      in
        hmFailure
        != null
        && lib.hasInfix "rules/default.rules" hmFailure.message
        && builtins.all (assertion: assertion.assertion) devenv.config.assertions
        && (execpolicyUnits devenv)."default.rules".text != ""
    );

    # Codex keeps a rules/*.rules entry only when DirEntry::file_type() says
    # regular file, and that call does not follow symlinks: a linked rule is
    # skipped silently ("loaded 0 .rules files"; codex 0.156.0). So both
    # backends must COPY each rule, claim it file by file, and keep the writer
    # when the last rule goes so the copy is retracted.
    module-codex-execpolicy-copies-not-links = mkTest "codex-execpolicy-copies-not-links" (
      let
        populated.ai.codex = {
          enable = true;
          execpolicyRules.probe = ''prefix_rule(pattern = ["git", "status"])'';
        };
        emptied.ai.codex.enable = true;
        # Disabling Codex while a rule is still declared: nothing but this
        # writer retracts a copy, so it has to survive the disable.
        disabled = lib.recursiveUpdate populated {ai.codex.enable = false;};
        copies = evaluate: let
          evaluated = evaluate populated;
          files = evaluated.config.home.file or evaluated.config.files;
          target = execpolicyTarget evaluated;
          off = evaluate disabled;
          offTarget = execpolicyTarget off;
        in
          target.codec
          == "dir"
          && lib.hasSuffix "/rules" target.path
          && lib.attrNames target.units == ["probe.rules"]
          && !(files ? ".codex/rules/probe.rules")
          && (execpolicyUnits (evaluate emptied)) == {}
          # Disabled: the same ledger, no units, so only retraction runs.
          && offTarget.units == {}
          && offTarget.ledger == target.ledger
          && offTarget.path == target.path
          && (
            if off.config ? home
            then lib.all (entry: off.config.home.activation ? ${entry}) ["materialize-codex-execpolicy-prune" "materialize-codex-execpolicy-write"]
            else off.config.tasks ? "ai:codex:materialize-execpolicy"
          );
      in
        copies evalHm && copies evalDevenv
    );

    # ── App-server daemon ───────────────────────────────────────────────────
    # Home Manager selects the package the shared daemon runs and turns off
    # upstream's updater and auto-start; devenv touches none of that and runs
    # Codex with --no-daemon. The selector's behavior against the real daemon
    # is chatgpt-codex-daemon-selection.nix; these hold the wiring.
    module-codex-daemon-hm-pins-package = mkTest "codex-daemon-hm-pins-package" (
      let
        hm = evalHm {ai.codex.enable = true;};
        select = hm.config.home.activation.codexDaemonSelect.text;
        # A regex needle cannot carry store-path context.
        packageRoot = builtins.unsafeDiscardStringContext "${aiStubs.chatgpt-codex}/${aiStubs.chatgpt-codex.passthru.codexPackage.root}";
      in
        # It rewrites a link in the user's Codex home, so DRY_RUN must echo it.
        hasLiteral "run /nix/store/" select
        && hasLiteral "/bin/codex-daemon-select \"$HOME\"/.codex ${packageRoot}" select
        && (daemonSettings hm).value == {updater.autoUpdateEnabled = false;}
        && (hmCodexSettings hm).features.daemon_auto_start == false
        && lib.all (assertion: assertion.assertion) hm.config.assertions
    );

    module-codex-daemon-hm-opt-outs = mkTest "codex-daemon-hm-opt-outs" (
      let
        unpinned = evalHm {
          ai.codex = {
            enable = true;
            pinDaemonToPackage = false;
          };
        };
        autoStart = evalHm {
          ai.codex = {
            enable = true;
            native.settings.features.daemon_auto_start = true;
          };
        };
        disabled = evalHm {ai.codex.pinDaemonToPackage = true;};
        releases = evaluated:
          hasLiteral "/bin/codex-daemon-select \"$HOME\"/.codex ''\n" evaluated.config.home.activation.codexDaemonSelect.text;
        settingsTarget = evaluated: lib.head (ownPlan "codex" "codexDaemonSettingsReconcile" evaluated).targets;
      in
        # Unpinned: the selection is released and the updater leaf retracted,
        # while auto-start stays off; the two are independent.
        releases unpinned
        && (daemonSettings unpinned).value == {}
        && (hmCodexSettings unpinned).features.daemon_auto_start == false
        && lib.all (assertion: assertion.assertion) unpinned.config.assertions
        && (hmCodexSettings autoStart).features.daemon_auto_start
        # Disabled: both writers still run, so a store selection cannot
        # outlive the package that GC removes, and the leaf is retracted.
        && releases disabled
        && (settingsTarget disabled).units == {}
        && (settingsTarget disabled).ledger == (settingsTarget unpinned).ledger
    );

    module-codex-daemon-hm-needs-package-layout = mkTest "codex-daemon-hm-needs-package-layout" (
      let
        foreign = pkgs.writeShellScriptBin "codex" "";
        failure = evaluated:
          lib.findFirst (assertion: !assertion.assertion) null evaluated.config.assertions;
        pinned = failure (evalHm {
          ai.codex = {
            enable = true;
            package = foreign;
          };
        });
      in
        pinned
        != null
        && hasLiteral "pinDaemonToPackage = false" pinned.message
        # A complete package at another root would be pinned and then never
        # released, because the selector only removes the shape it writes.
        && failure (evalHm {
          ai.codex = {
            enable = true;
            package = foreign // {passthru.codexPackage.root = "opt/codex";};
          };
        })
        != null
        && failure (evalHm {
          ai.codex = {
            enable = true;
            package = foreign;
            pinDaemonToPackage = false;
          };
        })
        == null
    );

    module-codex-daemon-devenv-runs-without-daemon = let
      devenv = evalDevenv {ai.codex.enable = true;};
    in
      assert lib.all (assertion: assertion.assertion) devenv.config.assertions;
      # devenv never writes user-scope daemon state.
      assert !lib.any (name: lib.hasInfix "daemon" (lib.toLower name)) (lib.attrNames devenv.config.tasks);
      assert !lib.any (lib.hasInfix "app-server-daemon") (lib.attrNames devenv.config.files);
        mkWrapperGrepTest {
          name = "codex-daemon-devenv-runs-without-daemon";
          package = lib.head devenv.config.packages;
          bin = "codex";
          needles = ["--no-daemon"];
        };

    module-codex-daemon-devenv-rejects-daemon-settings = mkTest "codex-daemon-devenv-rejects-daemon-settings" (
      let
        failures = config:
          map (assertion: assertion.message)
          (lib.filter (assertion: !assertion.assertion) (evalDevenv config).config.assertions);
        autoStart = failures {
          ai.codex = {
            enable = true;
            native.settings.features.daemon_auto_start = true;
          };
        };
        unpinned = failures {
          ai.codex = {
            enable = true;
            pinDaemonToPackage = false;
          };
        };
      in
        builtins.length autoStart
        == 1
        && hasLiteral "daemon_auto_start = true has no" (lib.head autoStart)
        && builtins.length unpinned == 1
        && hasLiteral "pinDaemonToPackage is Home Manager-only" (lib.head unpinned)
        # Off is what --no-daemon already means, so it is accepted.
        && failures {
          ai.codex = {
            enable = true;
            native.settings.features.daemon_auto_start = false;
          };
        }
        == []
    );

    module-codex-trust-is-user-global = mkTest "codex-trust-is-user-global" (
      let
        config.ai.codex = {
          enable = true;
          native.settings.projects."/home/test/project".trust_level = "trusted";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        failed = lib.findFirst (assertion: !assertion.assertion) null devenv.config.assertions;
      in
        (hmCodexSettings hm).projects."/home/test/project".trust_level
        == "trusted"
        && failed != null
        && lib.hasInfix "projects" failed.message
    );

    module-codex-settings-toml-syntax = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          native.settings = {
            features.memories = true;
            model = "custom-provider/model";
            model_reasoning_effort = "high";
          };
        };
      };
      source = tomlFormat.generate "codex-settings.toml" (hmCodexSettings evaluated);
    in
      pkgs.runCommand "module-test-codex-settings-toml-syntax" {} ''
        ${pkgs.gnugrep}/bin/grep -Fqx 'model = "custom-provider/model"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx 'model_reasoning_effort = "high"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx '[features]' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx 'memories = true' ${source}
        touch "$out"
      '';

    module-codex-settings-enums-reject-invalid = mkTest "codex-settings-enums-reject-invalid" (
      let
        accepts = name: value:
          (builtins.tryEval
            (hmCodexSettings (evalHm {
              ai.codex = {
                enable = true;
                native.settings.${name} = value;
              };
            })))
        .success;
        acceptsFeature = name: value:
          (builtins.tryEval
            (hmCodexSettings (evalHm {
              ai.codex = {
                enable = true;
                native.settings.features.${name} = value;
              };
            })))
        .success;
        acceptsPermission = path: value:
          (builtins.tryEval
            (hmCodexSettings (evalHm {
              ai.codex = {
                enable = true;
                native.settings.permissions.test = lib.setAttrByPath path value;
              };
            })))
        .success;
        # These two vocabularies come from recursive Clap help. Test the entire
        # extracted sets rather than one representative, so replacing the
        # factory's sidecar lookup with a stale handwritten subset goes red.
        extractedFlagValues = name: let
          matches = builtins.filter (flag: builtins.elem name flag.names) codexExtracted.cli.globalFlags;
          matchCount = builtins.length matches;
        in
          if matchCount == 1
          then (builtins.head matches).acceptedValues
          else throw "module-eval expected exactly one extracted Codex global flag record for ${name}, found ${toString matchCount}";
      in
        accepts "model_reasoning_effort" "max"
        && lib.all (accepts "approval_policy") (extractedFlagValues "--ask-for-approval")
        && accepts "approvals_reviewer" "auto_review"
        && accepts "personality" "friendly"
        && lib.all (accepts "sandbox_mode") (extractedFlagValues "--sandbox")
        && accepts "web_search" "live"
        && acceptsFeature "memories" true
        && acceptsFeature "speculative_future_flag" false
        && acceptsPermission ["filesystem" ":minimal"] "read"
        && acceptsPermission ["network" "domains" "api.openai.com"] "allow"
        && acceptsPermission ["network" "mode"] "limited"
        && !(accepts "model_reasoning_effort" "extreme")
        && !(accepts "approval_policy" "sometimes")
        && !(accepts "approvals_reviewer" "agent")
        && !(accepts "personality" "verbose")
        && !(accepts "sandbox_mode" "full")
        && !(accepts "web_search" "enabled")
        && !(acceptsFeature "memories" "yes")
        && !(acceptsFeature "speculative_future_flag" "no")
        && !(acceptsPermission ["filesystem" ":minimal"] "execute")
        && !(acceptsPermission ["filesystem" "glob_scan_max_depth"] 0)
        && !(acceptsPermission ["network" "domains" "api.openai.com"] "prompt")
        && !(acceptsPermission ["network" "mode"] "disabled")
    );

    module-codex-project-settings-reject-ignored-keys = mkTest "codex-project-settings-reject-ignored-keys" (
      let
        devenv = evalDevenv {
          ai.codex = {
            enable = true;
            native.settings = {
              model_provider = "custom";
              notify = ["notify-send"];
            };
          };
        };
        hm = evalHm {
          ai.codex = {
            enable = true;
            native.settings.model_provider = "custom";
          };
        };
        failed = lib.findFirst (assertion: !assertion.assertion) null devenv.config.assertions;
      in
        failed
        != null
        && lib.hasInfix "model_provider, notify" failed.message
        && (hmCodexSettings hm).model_provider == "custom"
    );

    module-codex-semantic-agents-fanout = mkTest "codex-semantic-agents-fanout" (
      let
        config.ai = {
          agents = {
            emptyTools = {
              description = "Review with an explicitly empty tool restriction.";
              instructions.text = "Report concrete findings.";
              tools = [];
            };
            reviewer = {
              codex = {
                model = "review-model";
                sandbox_mode = "read-only";
              };
              description = "Review changes for correctness.";
              instructions.text = "Read first, then report concrete findings.";
              tools = ["Bash" "Read"];
            };
            unrestricted = {
              description = "Review without a portable tool restriction.";
              instructions.text = "Report concrete findings.";
            };
          };
          claude.enable = true;
          codex.enable = true;
          copilot.enable = true;
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = {
          description = "Review changes for correctness.";
          developer_instructions = "Read first, then report concrete findings.";
          model = "review-model";
          name = "reviewer";
          sandbox_mode = "read-only";
        };
        hmAgent = hm.config.ai.codex.files.".codex/agents/reviewer.toml".content.source.value;
        devenvAgent = devenv.config.ai.codex.files.".codex/agents/reviewer.toml".content.source.value;
        claudeAgent = (markdownInput hm ".claude/agents/reviewer.md").text;
        emptyClaudeAgent = (markdownInput hm ".claude/agents/emptyTools.md").text;
        emptyCopilotAgent = (markdownInput devenv ".github/agents/emptyTools.agent.md").text;
        unrestrictedClaudeAgent = (markdownInput hm ".claude/agents/unrestricted.md").text;
        copilotAgent = (markdownInput devenv ".github/agents/reviewer.agent.md").text;
      in
        fromGeneratedTree ".codex/agents/reviewer.toml" hm.config.home.file.".codex/agents/reviewer.toml"
        && fromGeneratedTree ".codex/agents/reviewer.toml" devenv.config.files.".codex/agents/reviewer.toml"
        && fromGeneratedTree ".claude/agents/reviewer.md" hm.config.home.file.".claude/agents/reviewer.md"
        && hmAgent
        == expected
        && devenvAgent == expected
        && lib.hasPrefix "---\n" claudeAgent
        && lib.hasInfix ''name: "reviewer"'' claudeAgent
        && lib.hasInfix ''description: "Review changes for correctness."'' claudeAgent
        && lib.hasInfix "tools: Bash, Read" claudeAgent
        && !(lib.hasInfix "tools:" emptyClaudeAgent)
        && !(lib.hasInfix "tools:" emptyCopilotAgent)
        && lib.hasPrefix "---\n" unrestrictedClaudeAgent
        && lib.hasInfix ''description: "Review without a portable tool restriction."'' unrestrictedClaudeAgent
        && !(lib.hasInfix "tools:" unrestrictedClaudeAgent)
        && lib.hasInfix "Read first, then report concrete findings." copilotAgent
        && lib.hasInfix "tools: Bash, Read" copilotAgent
        && !(lib.hasInfix "name:" copilotAgent)
    );

    module-codex-agent-toml-syntax = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          agents.reviewer = {
            codex = {
              model = "review-model";
              sandbox_mode = "read-only";
            };
            description = "Review changes.";
            instructions.text = "Report concrete findings.";
          };
        };
      };
      source = evaluated.config.home.file.".codex/agents/reviewer.toml".source;
    in
      pkgs.runCommand "module-test-codex-agent-toml-syntax" {} ''
        ${pkgs.gnugrep}/bin/grep -Fqx 'name = "reviewer"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx 'model = "review-model"' ${source}
        ${pkgs.gnugrep}/bin/grep -Fqx 'sandbox_mode = "read-only"' ${source}
        touch "$out"
      '';

    module-codex-agent-runtime-replaces-root = mkTest "codex-agent-runtime-replaces-root" (
      let
        result = evalHm {
          ai = {
            agents.reviewer = {
              description = "Root review.";
              instructions.text = "Use root instructions.";
            };
            codex = {
              enable = true;
              agents.reviewer = {
                description = "Codex review.";
                instructions.text = "Use Codex instructions.";
              };
            };
          };
        };
        agent = result.config.ai.codex.files.".codex/agents/reviewer.toml".content.source.value;
      in
        fromGeneratedTree ".codex/agents/reviewer.toml" result.config.home.file.".codex/agents/reviewer.toml"
        && agent.description == "Codex review."
        && agent.developer_instructions == "Use Codex instructions."
    );

    module-codex-legacy-markdown-agent-fails-loudly = mkTest "codex-legacy-markdown-agent-fails-loudly" (
      let
        result = evalHm {
          ai.codex.enable = true;
          ai.agents.legacy = "# Legacy Markdown agent";
        };
      in
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "must use the portable" assertion.message)
        result.config.assertions
    );

    module-codex-agent-native-reserved-keys-fail = mkTest "codex-agent-native-reserved-keys-fail" (
      let
        result = evalDevenv {
          ai.codex = {
            enable = true;
            agents.reviewer = {
              description = "Review.";
              instructions.text = "Review carefully.";
              codex.name = "different-name";
            };
          };
        };
      in
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "keep name/description/developer_instructions out" assertion.message)
        result.config.assertions
    );

    # Each route into an `[mcp_servers.<name>.oauth]` table refuses a client
    # secret on both backends and names the declaration that renders it. The
    # `replaced` server proves the path follows pool precedence: its root
    # entry carries a secret that the runtime entry replaces and never renders.
    module-codex-mcp-oauth-client-secret-fail = mkTest "codex-mcp-oauth-client-secret-fail" (
      let
        oauth = {
          client_id = "confidential-client";
          client_secret = "must-not-reach-the-store";
        };
        remote = extra: {url = "https://example.test/mcp";} // extra;
        reviewAgent = {
          description = "Review.";
          instructions.text = "Review carefully.";
          codex.mcp_servers.tracker = remote {inherit oauth;};
        };
        pooled.ai = {
          agents.reviewer = reviewAgent;
          codex = {
            enable = true;
            agents.auditor = reviewAgent;
            mcpServers = {
              local = remote {codex.oauth = oauth;};
              replaced = remote {codex.oauth.client_id = "public-client";};
            };
          };
          mcpServers = {
            replaced = remote {codex.oauth = oauth;};
            shared = remote {codex.oauth = oauth;};
          };
        };
        native.ai.codex = {
          enable = true;
          native.settings.mcp_servers.direct = remote {inherit oauth;};
        };
        secretFailures = result:
          builtins.filter (assertion:
            !assertion.assertion
            && lib.hasInfix ".oauth.client_secret would copy" assertion.message)
          result.config.assertions;
        # Agent tables get the role-layer remedy, server tables the Nix-managed
        # credential routes; never the other's, and neither points at a runtime
        # `codex mcp` command, since Nix owns MCP configuration.
        rejectsExactly = paths: result: let
          failures = secretFailures result;
        in
          builtins.length failures
          == builtins.length (builtins.attrNames paths)
          && lib.all lib.id (lib.mapAttrsToList (path: remedy:
            builtins.any (assertion:
              lib.hasPrefix "${path}.oauth.client_secret would copy" assertion.message
              && lib.hasInfix remedy assertion.message
              && !(lib.hasInfix (
                  if remedy == agentRemedy
                  then serverRemedy
                  else agentRemedy
                )
                assertion.message)
              && !(lib.hasInfix "codex mcp " assertion.message))
            failures)
          paths);
        agentRemedy = "Codex role layers ignore mcp_servers";
        serverRemedy = "set proxy.enable with the";
        pooledPaths = {
          "ai.agents.reviewer.codex.mcp_servers.tracker" = agentRemedy;
          "ai.codex.agents.auditor.codex.mcp_servers.tracker" = agentRemedy;
          "ai.codex.mcpServers.local.codex" = serverRemedy;
          "ai.mcpServers.shared.codex" = serverRemedy;
        };
        nativePaths."ai.codex.native.settings.mcp_servers.direct" = serverRemedy;
      in
        builtins.all (evaluate:
          rejectsExactly pooledPaths (evaluate pooled)
          && rejectsExactly nativePaths (evaluate native))
        [evalDevenv evalHm]
    );

    # Positive control: an OAuth table without a secret evaluates and renders
    # unchanged on both backends.
    module-codex-mcp-oauth-public-client-renders = mkTest "codex-mcp-oauth-public-client-renders" (
      let
        config.ai = {
          codex.enable = true;
          mcpServers.remote = {
            url = "https://example.test/mcp";
            codex = {
              oauth = {
                callback_port = 8765;
                client_id = "public-client";
              };
              scopes = ["read"];
            };
          };
        };
        expected = {
          oauth = {
            callback_port = 8765;
            client_id = "public-client";
          };
          scopes = ["read"];
          url = "https://example.test/mcp";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        failed = result: builtins.filter (assertion: !assertion.assertion) result.config.assertions;
      in
        failed hm
        == []
        && failed devenv == []
        && (hmCodexSettings hm).mcp_servers.remote == expected
        && devenv.config.ai.codex.files.".codex/config.toml".content.source.value.mcp_servers.remote == expected
    );

    module-codex-agent-defaults-parity = mkTest "codex-agent-defaults-parity" (
      let
        config.ai.codex = {
          enable = true;
          native.settings.agents = {
            default_subagent_model = "worker-model";
            default_subagent_reasoning_effort = "high";
            enabled = true;
            interrupt_message = false;
            max_concurrent_threads_per_session = 7;
          };
        };
        hmAgents = (hmCodexSettings (evalHm config)).agents;
        devenvAgents = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.source.value.agents;
      in
        hmAgents
        == devenvAgents
        && hmAgents.default_subagent_model == "worker-model"
        && hmAgents.default_subagent_reasoning_effort == "high"
        && hmAgents.max_concurrent_threads_per_session == 7
        && !hmAgents.interrupt_message
    );

    module-codex-hooks-fanout-parity = mkTest "codex-hooks-fanout-parity" (
      let
        config.ai = {
          claude.enable = true;
          codex = {
            enable = true;
            hooks.PreToolUse = [
              {
                matcher = "apply_patch";
                hooks = [
                  {
                    additionalContextLimit = 0;
                    command = "review-patch";
                    commandWindows = "review-patch.exe";
                    statusMessage.text = "Reviewing patch";
                    timeout = 30;
                  }
                ];
              }
            ];
          };
          hooks.PreToolUse = [
            {
              matcher = "Bash";
              hooks = [{command = pkgs.hello;}];
            }
          ];
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmHooks = hm.config.ai.codex.files.".codex/hooks.json".content.source.value;
        devenvHooks = devenv.config.ai.codex.files.".codex/hooks.json".content.source.value;
        blocks = hmHooks.hooks.PreToolUse;
        sharedHandler = builtins.head (builtins.head blocks).hooks;
        nativeHandler = builtins.head (builtins.elemAt blocks 1).hooks;
        claudeBlocks = (claudeSettings hm).hooks.PreToolUse;
      in
        hmHooks
        == devenvHooks
        && builtins.length blocks == 2
        && lib.hasSuffix "/bin/hello" sharedHandler.command
        && nativeHandler.additionalContextLimit == 0
        && nativeHandler.commandWindows == "review-patch.exe"
        && nativeHandler.statusMessage == "Reviewing patch"
        && builtins.length claudeBlocks == 1
        && (builtins.head claudeBlocks).matcher == "Bash"
    );

    module-codex-hooks-inline-source-collision-fails = mkTest "codex-hooks-inline-source-collision-fails" (
      let
        result = evalHm {
          ai.codex = {
            enable = true;
            hooks.Stop = [{hooks = [{command = "validate";}];}];
            native.settings.hooks.Stop = [{hooks = [{command = "legacy";}];}];
          };
        };
      in
        builtins.any (assertion:
          !assertion.assertion
          && lib.hasInfix "cannot be combined with ai.codex.native.settings.hooks" assertion.message)
        result.config.assertions
    );

    module-codex-hooks-json-syntax = let
      evaluated = evalDevenv {
        ai.codex = {
          enable = true;
          hooks.Stop = [{hooks = [{command = "validate";}];}];
        };
      };
      source = evaluated.config.files.".codex/hooks.json".source;
    in
      pkgs.runCommand "module-test-codex-hooks-json-syntax" {} ''
        ${pkgs.jq}/bin/jq -e '.hooks.Stop[0].hooks[0]
          | .type == "command" and .command == "validate"' ${source} >/dev/null
        touch "$out"
      '';

    module-codex-agentsmd-fanout = mkTest "codex-agentsmd-fanout" (
      let
        config = {
          ai = {
            codex = {
              context.text = "Codex context";
              enable = true;
              rules.zeta.text = "Zeta rule";
            };
            context.text = "Shared context";
            rules.alpha.text = "Alpha rule";
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = builtins.concatStringsSep "\n\n" [
          "<!-- rule: alpha -->\n\nAlpha rule"
          "<!-- rule: zeta -->\n\nZeta rule"
          "Shared context"
          "Codex context"
        ];
      in
        (markdownInput hm ".codex/AGENTS.md").text
        == expected
        && (markdownInput devenv "AGENTS.md").text == expected
        && !(lib.hasInfix "---" expected)
    );

    module-codex-context-fallback-and-empty-gate = mkTest "codex-context-fallback-and-empty-gate" (
      let
        hm = evalHm {
          ai = {
            codex.enable = true;
            context.text = "Shared context";
          };
        };
        empty = evalHm {ai.codex.enable = true;};
      in
        (markdownInput hm ".codex/AGENTS.md").text
        == "Shared context"
        && !(empty.config.home.file ? ".codex/AGENTS.md")
    );

    module-codex-configdir-rejects-unsafe-paths = mkTest "codex-configdir-rejects-unsafe-paths" (
      let
        accepts = configDir:
          (builtins.tryEval
            (evalHm {
              ai.codex = {
                inherit configDir;
                enable = true;
              };
            }).config.ai.codex.configDir)
        .success;
      in
        accepts ".codex"
        && !(accepts "")
        && !(accepts "/tmp/codex")
        && !(accepts "../codex")
        && !(accepts "config/../codex")
    );

    module-codex-scoped-content-degrades-to-prose = mkTest "codex-scoped-content-degrades-to-prose" (
      let
        config = {
          ai = {
            codex = {
              enable = true;
            };
            rules.scoped = {
              matcher = ["src/**"];
              text = "Scoped rule";
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = "<!-- rule: scoped -->\n\n_Apply this guidance only when working with files matching: `src/**`_\n\nScoped rule";
      in
        (markdownInput hm ".codex/AGENTS.md").text
        == expected
        && (markdownInput devenv "AGENTS.md").text == expected
    );

    # A scoped rule that names the documents holding its text is listed, not
    # inlined: the flat file carries its globs and links, never its body. An
    # unscoped rule with references stays inline, because an index entry with
    # no globs could never tell the reader when to follow it.
    module-codex-scoped-references-render-index = mkTest "codex-scoped-references-render-index" (
      let
        config = {
          ai = {
            codex.enable = true;
            context.text = "Shared context";
            rules = {
              always = {
                references = ["docs/always.md"];
                text = "Always body";
              };
              beta = {
                matcher = ["b/**"];
                references = ["docs/b.md"];
                text = "Beta body";
              };
              alpha = {
                matcher = ["a/**" "lib/a.nix"];
                references = ["docs/a.md" "docs/a-more.md"];
                text = "Alpha body";
              };
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        expected = builtins.concatStringsSep "\n\n" [
          (
            "## Path-scoped rules\n\n"
            + "Before editing a path that matches an entry below, read every document listed\n"
            + "for it. When several entries match, their guidance composes.\n\n"
            + "- **`alpha`**\n  - Match:\n    - `a/**`\n    - `lib/a.nix`\n"
            + "  - Read:\n    - [`docs/a.md`](docs/a.md)\n    - [`docs/a-more.md`](docs/a-more.md)\n"
            + "- **`beta`**\n  - Match:\n    - `b/**`\n  - Read:\n    - [`docs/b.md`](docs/b.md)\n"
          )
          "<!-- rule: always -->\n\nAlways body"
          "Shared context"
        ];
      in
        (markdownInput hm ".codex/AGENTS.md").text
        == expected
        && (markdownInput devenv "AGENTS.md").text == expected
        && devenv.config.ai.internal.agentsMd."AGENTS.md".index ? alpha
        && !(devenv.config.ai.internal.agentsMd."AGENTS.md".rules ? alpha)
    );

    # The guard and Codex's own limit are one number: a raised guard reaches
    # config.toml on both backends, the default writes nothing, and an
    # explicit native value still wins.
    module-codex-project-doc-limit-reaches-native = mkTest "codex-project-doc-limit-reaches-native" (
      let
        settingsOf = eval: eval.config.ai.codex.native.settings;
        raised = extra: {
          ai.codex =
            {
              enable = true;
              projectDocMaxBytes = 131072;
            }
            // extra;
        };
        hmRaised = evalHm (raised {});
        devenvRaised = evalDevenv (raised {});
        devenvDefault = evalDevenv {ai.codex.enable = true;};
        explicit = evalDevenv (raised {native.settings.project_doc_max_bytes = 65536;});
      in
        (settingsOf hmRaised).project_doc_max_bytes
        == 131072
        && (settingsOf devenvRaised).project_doc_max_bytes == 131072
        && !((settingsOf devenvDefault) ? project_doc_max_bytes)
        && (settingsOf explicit).project_doc_max_bytes == 65536
    );

    # Codex's limit is checked on the BUILT file, in the tree that delivers
    # it. Home Manager keys it by `.codex/AGENTS.md`, so a replacement is
    # measured as well as the generated file: the generated file is exactly
    # the generated tree `mkTree` builds with that limit (and the evaluation's
    # formatter, checks and guards). A replacement with no `format` is `raw`
    # in the same tree. The build fails one byte past the limit. The arithmetic is
    # `checks/markdown/markdown-byte-limit-scripts.nix`.
    module-codex-agents-md-byte-limit = let
      path = ".codex/AGENTS.md";
      hint = "Trim or replace the final content, or raise ai.codex.projectDocMaxBytes.";
      limit.${path} = {
        bytes = 32768;
        inherit hint;
      };
      generated = evalHm {
        ai.codex = {
          context.text = "CONTEXT";
          enable = true;
        };
      };
      replaced = size:
        evalHm {
          ai.codex = {
            enable = true;
            files.${path}.content.text = lib.concatStrings (lib.replicate (size - 1) "x") + "\n";
          };
        };
      treeFor = evaluated:
        (aiBase.generated pkgs).mkTree {
          name = "ai-hm-codex-generated";
          files.${path} = markdownInput evaluated path // {type = evaluated.config.ai.codex.files.${path}.format;};
          inherit (evaluated.config.ai.generated) check formatter guards;
          maxBytes = limit;
        };
      deliversFrom = tree: evaluated: evaluated.config.home.file.${path}.source == "${tree}/${path}";
      exact = replaced 32768;
      above = replaced 32769;
      failure = pkgs.testers.testBuildFailure (treeFor above);
    in
      assert lib.assertMsg (generated.config.ai.codex._maxBytes == limit && exact.config.ai.codex._maxBytes == limit)
      "codex-agents-md-byte-limit: ai.codex._maxBytes is not the 32768-byte limit on ${path}";
      assert lib.assertMsg (lib.all (evaluated: deliversFrom (treeFor evaluated) evaluated) [generated exact above])
      "codex-agents-md-byte-limit: ${path} is not delivered from a tree carrying its limit";
        pkgs.runCommand "module-test-codex-agents-md-byte-limit" {} ''
          test -f ${treeFor exact}/${path}
          grep -q -F ${lib.escapeShellArg "${path} renders to 32769 bytes, exceeding its limit (32768 bytes). ${hint}"} ${failure}/testBuildFailure.log
          echo PASS > "$out"
        '';

    # On devenv a RAISED limit lands in trust-gated project config, so a file
    # past Codex's own 32 KiB is all an untrusted project reads. Every shell
    # entry runs the window notice on the project's AGENTS.md, which it
    # measures whoever wrote it; a limit at the default runs nothing. Home
    # Manager writes the limit to user config, which no trust gates, and has
    # no shell entry. What the notice prints is
    # `checks/markdown/markdown-byte-limit-scripts.nix`.
    module-codex-window-notice = mkTest "codex-window-notice" (
      let
        expected = ["${lib.getExe (import ../../../lib/markdown/byte-limit.nix pkgs).windowNotice} \"$DEVENV_ROOT\"/${lib.escapeShellArgs ["AGENTS.md" "32768" "codex"]}"];
        devenv = projectDocMaxBytes:
          evalDevenv {
            ai = {
              codex = {
                enable = true;
                inherit projectDocMaxBytes;
              };
              context.text = "CONTEXT";
            };
          };
        hm = evalHm {
          ai.codex = {
            context.text = "CONTEXT";
            enable = true;
            projectDocMaxBytes = 131072;
          };
        };
        # A store-backed replacement with no `format` is `raw`, as on Home
        # Manager: it is in the shared generated tree, under the limit.
        replaced = evalDevenv {
          ai.codex = {
            enable = true;
            files."AGENTS.md".content.source = pkgs.writeText "big" (lib.concatStrings (lib.replicate 40000 "x"));
            projectDocMaxBytes = 131072;
          };
        };
      in
        windowNoticeLines (devenv 32768)
        == []
        && windowNoticeLines (devenv 131072) == expected
        && windowNoticeLines replaced == expected
        && replaced.config.ai.internal._maxBytes."AGENTS.md".bytes == 131072
        && fromGeneratedTree "AGENTS.md" (deliveredFiles replaced.config)."AGENTS.md"
        && hm.config.ai.codex._maxBytes.".codex/AGENTS.md".bytes == 131072
        && hm.config.warnings == []
    );

    # `format = "raw"` delivers AGENTS.md as written on both backends. It is
    # built into the generated tree, which measures it and neither formats nor
    # checks it: the three spaces in the text survive, where the default
    # formatter would collapse them to one. Past the limit the same entry
    # still fails the build. The devenv entry reaches the shared AGENTS.md
    # owner with its own format.
    module-codex-raw-agents-md-is-measured-not-formatted = let
      text = "RAW   REPLACEMENT\n";
      raw.content.text = text;
      raw.format = "raw";
      hm = projectDocMaxBytes:
        evalHm {
          ai.codex = {
            enable = true;
            files.".codex/AGENTS.md" = raw;
            inherit projectDocMaxBytes;
          };
        };
      devenv = projectDocMaxBytes:
        evalDevenv {
          ai.codex = {
            enable = true;
            files."AGENTS.md" = raw;
            inherit projectDocMaxBytes;
          };
        };
      # The tree the router must deliver each from: the text and processing
      # options, under the evaluation's own limit.
      cases = {
        hm = evaluated: {
          delivered = evaluated.config.home.file.".codex/AGENTS.md".source;
          inherit (evaluated.config.ai.generated) check formatter guards;
          maxBytes = evaluated.config.ai.codex._maxBytes;
          name = "ai-hm-codex-generated";
          path = ".codex/AGENTS.md";
        };
        devenv = evaluated: {
          delivered = (deliveredFiles evaluated.config)."AGENTS.md".source;
          inherit (evaluated.config.ai.generated) check formatter guards;
          maxBytes = evaluated.config.ai.internal._maxBytes;
          name = "ai-devenv-internal-generated";
          path = "AGENTS.md";
        };
      };
      expectedTree = case:
        (aiBase.generated pkgs).mkTree {
          inherit (case) maxBytes name;
          inherit (case) check formatter guards;
          files.${case.path} = {
            inherit text;
            type = "raw";
          };
        };
      checked = backend: evaluated: let
        case = cases.${backend} evaluated;
        tree = expectedTree case;
      in
        assert lib.assertMsg (case.delivered == "${tree}/${case.path}")
        "codex-raw-agents-md-is-measured-not-formatted: ${backend} ${case.path} is not delivered from the generated tree built from its text"; tree;
      fits = {
        devenv = checked "devenv" (devenv 32768);
        hm = checked "hm" (hm 32768);
      };
      # 16 bytes: the 18-byte text is past it.
      past = lib.mapAttrs (_backend: pkgs.testers.testBuildFailure) {
        devenv = checked "devenv" (devenv 16);
        hm = checked "hm" (hm 16);
      };
      expected = pkgs.writeText "raw-agents-md" text;
    in
      assert lib.assertMsg ((devenv 32768).config.ai.internal.files."AGENTS.md".format == "raw")
      "codex-raw-agents-md-is-measured-not-formatted: the shared AGENTS.md owner did not take the entry's `raw` format";
        pkgs.runCommand "module-test-codex-raw-agents-md-is-measured-not-formatted" {} ''
          cmp -- ${fits.hm}/.codex/AGENTS.md ${expected}
          cmp -- ${fits.devenv}/AGENTS.md ${expected}
          grep -q -F ${lib.escapeShellArg ".codex/AGENTS.md renders to 18 bytes, exceeding its limit (16 bytes)."} ${past.hm}/testBuildFailure.log
          grep -q -F ${lib.escapeShellArg "AGENTS.md renders to 18 bytes, exceeding its limit (16 bytes)."} ${past.devenv}/testBuildFailure.log
          echo PASS > "$out"
        '';

    # The shared AGENTS.md carries the limit of every runtime that reads it,
    # whoever supplies the content: here Codex's limit, and Kiro's rule alone.
    # The internal tree is built with that limit and fails past it.
    module-codex-shared-byte-limit-covers-kiro-only-content = let
      hint = "Trim the contributing context or rules, replace the final file, or raise the runtime's document-size limit.";
      limit."AGENTS.md" = {
        bytes = 16;
        inherit hint;
      };
      oversized = evalDevenv {
        ai = {
          codex = {
            enable = true;
            projectDocMaxBytes = 16;
          };
          kiro = {
            enable = true;
            rules.kiro-only.text = lib.concatStrings (lib.replicate 32 "x");
          };
        };
      };
      empty = evalDevenv {ai.codex.enable = true;};
      tree = (aiBase.generated pkgs).mkTree {
        name = "ai-devenv-internal-generated";
        files."AGENTS.md" = markdownInput oversized "AGENTS.md" // {type = oversized.config.ai.internal.files."AGENTS.md".format;};
        inherit (oversized.config.ai.generated) check formatter guards;
        maxBytes = limit;
      };
      failure = pkgs.testers.testBuildFailure tree;
    in
      assert lib.assertMsg (oversized.config.ai.internal._maxBytes == limit)
      "codex-shared-byte-limit-covers-kiro-only-content: ai.internal._maxBytes is not Codex's limit on AGENTS.md";
      assert lib.assertMsg ((deliveredFiles oversized.config)."AGENTS.md".source == "${tree}/AGENTS.md")
      "codex-shared-byte-limit-covers-kiro-only-content: AGENTS.md is not delivered from a tree carrying its limit";
      assert lib.assertMsg (!((deliveredFiles empty.config) ? "AGENTS.md"))
      "codex-shared-byte-limit-covers-kiro-only-content: a limit alone delivered an AGENTS.md";
        pkgs.runCommand "module-test-codex-shared-byte-limit-covers-kiro-only-content" {} ''
          grep -q -F ${lib.escapeShellArg "AGENTS.md renders to"} ${failure}/testBuildFailure.log
          grep -q -F ${lib.escapeShellArg hint} ${failure}/testBuildFailure.log
          echo PASS > "$out"
        '';

    # A body that writes AGENTS.md at activation has no bytes to measure when
    # the tree is built, so its limit is not checked, and the router says so
    # rather than dropping the limit silently. The inline control is quiet.
    module-codex-run-byte-limit-warns = mkTest "codex-run-byte-limit-warns" (
      let
        withContent = content:
          evalDevenv {
            ai.codex = {
              enable = true;
              files."AGENTS.md" = {
                inherit content;
                format = "raw";
              };
            };
          };
        limitWarnings = evaluated: lib.filter (lib.hasInfix "-byte limit is not checked") evaluated.config.warnings;
      in
        limitWarnings (withContent {run = "printf probe";})
        == [''ai.internal.files."AGENTS.md" is written at activation (`content.run`), so its 32768-byte limit is not checked.'']
        && limitWarnings (withContent {text = "probe";}) == []
    );

    module-codex-rule-runtime-replaces-root = mkTest "codex-rule-runtime-replaces-root" (
      let
        evaluated = evalHm {
          ai = {
            codex = {
              enable = true;
              rules.duplicate.text = "Codex";
            };
            rules.duplicate.text = "Shared";
          };
        };
      in
        lib.hasInfix "Codex" (markdownInput evaluated ".codex/AGENTS.md").text
        && !(lib.hasInfix "Shared" (markdownInput evaluated ".codex/AGENTS.md").text)
    );
  };
}
