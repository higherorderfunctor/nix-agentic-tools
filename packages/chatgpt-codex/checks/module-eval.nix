# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (harness) aiStubs checkRows claudeSettings deliveredFiles deliveredTree evalDevenv evalDevenvWithGetEnv evalDevenvWithSpecialArgs evalHm fromGeneratedTree hasLiteral markdownInput mkTest mkWrapperGrepTest rejectsChange tomlFormat;
  # Read the per-file engine plan; absent copies remain absent, including
  # when the runtime is disabled or its last rule is withdrawn.
  engineTargets = evaluated:
    (import ../../ai-module/lib/files/default.nix {inherit lib pkgs;}).normalize {
      backend =
        if evaluated.config ? home
        then "hm"
        else "devenv";
      files = evaluated.config.ai.files;
      namespace = "ai";
    };
  targetAt = evaluated: path:
    lib.findFirst (target: target.path == path) null (engineTargets evaluated);
  daemonSettingsTarget = evaluated:
    targetAt evaluated "${evaluated.config.ai.codex.configDir}/app-server-daemon/settings.json";
  daemonSettings = evaluated: let
    target = daemonSettingsTarget evaluated;
  in
    if target == null
    then null
    else target.content.value;
  agentSource = evaluated: name:
    evaluated.config.ai.codex._generatedFiles.".codex/agents/${name}.toml".content.source;
  renderedAgent = name: value: toString (tomlFormat.generate "codex-agent-${name}.toml" value);
  execpolicyRule = evaluated: name: targetAt evaluated ".codex/rules/${name}";
  execpolicyInput = evaluated: name: markdownInput evaluated ".codex/rules/${name}";
  failedAssertions = evaluated:
    map (entry: entry.message) (lib.filter (entry: !entry.assertion) evaluated.config.assertions);
  failsWith = fragment: evaluated:
    lib.any (lib.hasInfix fragment) (failedAssertions evaluated);
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) codexGlobalFlags hmCodexSettings withHmDefaults;
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

    module-codex-update-check-default-overridable = mkTest "codex-update-check-default-overridable" (
      let
        check = eval: isHm: let
          evaluate = settings: package:
            eval {
              ai.codex = {
                enable = true;
                inherit package;
                native.settings = settings;
              };
            };
          files = evaluated: evaluated.config.ai.codex.files;
          settings = evaluated: (files evaluated).".codex/config.toml".content.value or {};
          read = evaluated: (settings evaluated).check_for_update_on_startup;
          managed = settingsValue: evaluate settingsValue aiStubs.chatgpt-codex;
          unmanaged = settingsValue: evaluate settingsValue null;
          onlyInUserConfig = evaluated: expected:
            if isHm
            then read evaluated == expected
            else !((files evaluated) ? ".codex/config.toml");
        in
          checkRows "Codex update-check config ownership" {
            "a managed override belongs in Home Manager config, never project config" =
              onlyInUserConfig (managed {check_for_update_on_startup = true;}) true;
            "an unmanaged package must not receive a managed default" =
              !((settings (unmanaged {})) ? check_for_update_on_startup);
            "explicit false reaches config without a managed launcher" =
              read (unmanaged {check_for_update_on_startup = false;}) == false;
            "explicit true reaches config without a managed launcher" =
              read (unmanaged {check_for_update_on_startup = true;}) == true;
          };
      in
        checkRows "Codex update-check backends" {
          "Home Manager" = check evalHm true;
          "devenv" = check evalDevenv false;
        }
    );

    # Both backends always install a launcher for the document preflight.
    # Devenv additionally carries --no-daemon and its Git SSH environment.
    module-codex-enabled-installs-package = mkTest "codex-enabled-installs-package" (
      let
        hm = evalHm {ai.codex.enable = true;};
        devenv = evalDevenv {ai.codex.enable = true;};
        hmPackages = hm.config.home.packages;
        devenvPackages = devenv.config.packages;
      in
        builtins.length hmPackages
        == 1
        && builtins.length devenvPackages == 1
    );

    module-codex-package-null-hm-configures-unpinned = mkTest "codex-package-null-hm-configures-unpinned" (
      let
        evaluated = evalHm {
          ai.codex = {
            enable = true;
            package = null;
            pinDaemonToPackage = false;
            native.settings.model = "gpt-package-null";
          };
        };
      in
        evaluated.config.home.packages
        == []
        && (hmCodexSettings evaluated).model == "gpt-package-null"
        && lib.all (entry: entry.assertion) evaluated.config.assertions
        # Explicit `false` is already the coherent "don't pin" state, so
        # there is nothing inert to name.
        && evaluated.config.warnings == []
    );

    # Default priority (unset) stays silent: `pinDaemonToPackage` defaults to
    # `true`, but a default the consumer never wrote is not a setting they
    # need to be told is inert.
    module-codex-package-null-hm-default-silent = mkTest "codex-package-null-hm-default-silent" (
      let
        evaluated = evalHm {
          ai.codex = {
            enable = true;
            package = null;
          };
        };
      in
        lib.all (entry: entry.assertion) evaluated.config.assertions
        && evaluated.config.warnings == []
    );

    module-codex-package-null-hm-explicit-pin-warns = mkTest "codex-package-null-hm-explicit-pin-warns" (
      let
        evaluated = evalHm {
          ai.codex = {
            enable = true;
            package = null;
            pinDaemonToPackage = true;
          };
        };
      in
        lib.all (entry: entry.assertion) evaluated.config.assertions
        && evaluated.config.warnings
        == ["ai.codex.package is null, so ai.codex.pinDaemonToPackage is inert: there is no package to pin the daemon to."]
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
          (evalDevenvWithGetEnv (name: environment.${name} or "") settings).config.ai.codex.files.".codex/config.toml".content.value.sandbox_workspace_write.writable_roots;
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
          (evalDevenvWithGetEnv (name: environment.${name} or "") settings).config.ai.codex.files.".codex/config.toml".content.value;
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
            }).config.ai.codex.files.".codex/config.toml".content.value;
        namedSettings = {
          default_permissions = "project-edit";
          permissions.project-edit.extends = ":workspace";
        };
        primary = evaluate "/repos/main" namedSettings;
        sibling = evaluate "/repos/sibling" namedSettings;
        arbitrary = evaluate "/scratch/agent" namedSettings;
        directoryCommon = evaluate "/repos/separate" namedSettings;
        legacy = evaluate "/repos/sibling" {sandbox_mode = "workspace-write";};
        denied = evaluate "/repos/sibling" (lib.recursiveUpdate namedSettings {
          permissions.project-edit.filesystem."/repos/main/.git" = "deny";
        });
        primaryFilesystem = primary.permissions.project-edit.filesystem;
        siblingFilesystem = sibling.permissions.project-edit.filesystem;
        arbitraryFilesystem = arbitrary.permissions.project-edit.filesystem;
        rejectsInvalidGitDir = invalid:
          rejectsChange (root: (evaluate root namedSettings).permissions.project-edit) {
            valid = "/repos/plain";
            inherit invalid;
            expected = {extends = ":workspace";};
          };
      in
        primaryFilesystem."/repos/main/.git"
        == "write"
        && siblingFilesystem."/repos/main/.git" == "write"
        && arbitraryFilesystem."/repos/main/.git" == "write"
        && directoryCommon.permissions.project-edit.filesystem."/repos/separate/shared-git" == "write"
        && !(siblingFilesystem ? "/repos/sibling/.git")
        && !(siblingFilesystem ? "/repos/main/.git/worktrees/sibling")
        && !(siblingFilesystem ? "/repos/main/.git/.git")
        && legacy.sandbox_workspace_write.writable_roots == ["/repos/sibling/.git"]
        && denied.permissions.project-edit.filesystem."/repos/main/.git" == "deny"
        && checkRows "Codex Git metadata resolution" {
          "a malformed gitdir pointer is not treated as absent Git metadata" = rejectsInvalidGitDir "/repos/malformed";
          "a gitdir pointer to the filesystem root is rejected" = rejectsInvalidGitDir "/repos/unsafe";
        }
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
        fromGeneratedTree ".agents/skills/local" hm.config.home.file.".agents/skills/local"
        && (markdownInput hm ".agents/skills/local").source == "${../../claude-code/checks/fixtures/claude-skills/skill-b}"
        && !(hm.config.home.file.".agents/skills/local" ? recursive)
        && fromGeneratedTree ".agents/skills/shared" hm.config.home.file.".agents/skills/shared"
        && (markdownInput hm ".agents/skills/shared").source == "${../../claude-code/checks/fixtures/claude-skills/skill-a}"
        && fromGeneratedTree ".agents/skills/local" devenv.config.files.".agents/skills/local"
        && (markdownInput devenv ".agents/skills/local").source == "${../../claude-code/checks/fixtures/claude-skills/skill-b}"
        && fromGeneratedTree ".agents/skills/shared" devenv.config.files.".agents/skills/shared"
        && (markdownInput devenv ".agents/skills/shared").source == "${../../claude-code/checks/fixtures/claude-skills/skill-a}"
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
      source = (deliveredFiles evaluated.config).".agents/skills/single".source;
    in
      assert fromGeneratedTree ".agents/skills/single" evaluated.config.home.file.".agents/skills/single";
        pkgs.runCommand "module-test-codex-single-file-skill-wraps-directory" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          cmp ${../../claude-code/checks/fixtures/claude-skills/skill-a/SKILL.md} ${source}/SKILL.md
          touch "$out"
        '';

    module-codex-unsafe-skill-name-fails = mkTest "codex-unsafe-skill-name-fails" (
      let
        check = eval: let
          evaluate = name:
            eval {
              ai.codex = {
                enable = true;
                skills.${name} = ../../claude-code/checks/fixtures/claude-skills/skill-a;
              };
            };
          valid = evaluate "local";
        in
          checkRows "Codex skill names" {
            "a safe name delivers its skill under .agents/skills" =
              failedAssertions valid
              == []
              && (markdownInput valid ".agents/skills/local").source == "${../../claude-code/checks/fixtures/claude-skills/skill-a}";
            "a parent traversal is not a single safe path component" =
              failsWith "single safe path components" (evaluate "../escape");
          };
      in
        checkRows "Codex skill backends" {
          "Home Manager" = check evalHm;
          "devenv" = check evalDevenv;
        }
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
        fromGeneratedTree ".agents/skills/duplicate" evaluated.config.home.file.".agents/skills/duplicate"
        && (markdownInput evaluated ".agents/skills/duplicate").source == "${../../claude-code/checks/fixtures/claude-skills/skill-b}"
    );

    # Home Manager always owns the user config.toml, as a store symlink even
    # when empty, so Codex never creates a writable one of its own; devenv
    # writes the project file only when something is declared.
    module-codex-empty-settings-toml-ownership = mkTest "codex-empty-settings-toml-ownership" (
      let
        config.ai.codex = {
          enable = true;
          native.settings = {
            # Null beats Home Manager's mkDefault, as it does every default.
            check_for_update_on_startup = null;
            features.daemon_auto_start = null;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        hm.config.home.file ? ".codex/config.toml"
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
        && devenv.config.ai.codex.files.".codex/config.toml".content.value.mcp_servers == expected
    );

    module-codex-mcp-freeform-rejects-non-toml = mkTest "codex-mcp-freeform-rejects-non-toml" (
      let
        readFuture = future:
          (hmCodexSettings (evalHm {
            ai.codex = {
              enable = true;
              mcpServers.docs = {
                command = "/bin/docs";
                codex = {inherit future;};
              };
            };
          })).mcp_servers.docs.future;
      in
        checkRows "Codex MCP freeform values" {
          "an unknown key may contain TOML text, not a function" = rejectsChange readFuture {
            valid = "future-value";
            invalid = value: value;
            expected = "future-value";
          };
        }
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
              settings.credentials = redact.file "/run/secrets/context7-api-key";
            };
            effect-mcp.url = "http://127.0.0.1:19760/mcp";
            git-intel-mcp.package = pkgs.hello;
            github-mcp = {
              package = pkgs.hello;
              settings.credentials = redact.file "/run/secrets/github-token";
            };
            nixos-mcp.url = "http://127.0.0.1:19761/mcp";
            openmemory = {
              command = "/bin/openmemory";
              args = ["mcp"];
            };
          };
        };
        hmServers = (hmCodexSettings (evalHm config)).mcp_servers;
        devenvServers = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.value.mcp_servers;
        credentialServer = hmServers.context7-mcp;
      in
        hmServers
        == devenvServers
        && builtins.attrNames hmServers
        == [
          "context7-mcp"
          "effect-mcp"
          "git-intel-mcp"
          "github-mcp"
          "nixos-mcp"
          "openmemory"
        ]
        && lib.hasInfix "context7-mcp-env" credentialServer.command
        && lib.take 2 credentialServer.args == ["--transport" "stdio"]
        && !(lib.hasInfix "/run/secrets/context7-api-key" (builtins.toJSON credentialServer))
        && lib.hasInfix "github-mcp-env" hmServers.github-mcp.command
        && hmServers.effect-mcp.url == "http://127.0.0.1:19760/mcp"
        && hmServers.openmemory.command == "/bin/openmemory"
    );

    module-codex-mcp-native-table-collision-fails = mkTest "codex-mcp-native-table-collision-fails" (
      let
        evaluate = withShared:
          evalHm {
            ai = {
              codex = {
                enable = true;
                native.settings.mcp_servers.native.command = "native";
              };
              mcpServers = lib.optionalAttrs withShared {shared.command = "shared";};
            };
          };
        valid = evaluate false;
      in
        checkRows "Codex MCP table source" {
          "a native-only server is delivered without a shared pool" =
            failedAssertions valid == [] && (hmCodexSettings valid).mcp_servers == {native.command = "native";};
          "a populated shared pool cannot coexist with a populated native table" =
            failsWith "native.settings.mcp_servers cannot be combined with ai.mcpServers/ai.codex.mcpServers" (evaluate true);
        }
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
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.value;
      in
        hmCodexSettings hm
        == withHmDefaults expected
        && devenvSettings == expected
    );

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
        devenv = evalDevenvWithGetEnv (_: "") config;
        hmSettings = hmCodexSettings hm;
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.value;
        expected = config.ai.codex.native.settings;
        withRoots = roots:
          lib.recursiveUpdate expected {sandbox_workspace_write.writable_roots = roots;};
      in
        checkRows "Codex legacy security settings" {
          "Home Manager retains the declared sandbox with its cache root" =
            hmSettings == withHmDefaults (withRoots ["/var/lib/project-cache" "/home/test/.cache/nix"]);
          "devenv retains the declared sandbox with only the project Git root added" =
            devenvSettings == withRoots ["/var/lib/project-cache" "/tmp/devenv-root/.git"];
        }
    );

    module-codex-security-models-do-not-compose = mkTest "codex-security-models-do-not-compose" (
      let
        evaluate = backend: settings:
          backend {
            ai.codex = {
              enable = true;
              native.settings = settings;
            };
          };
        legacy.sandbox_mode = "read-only";
        named.default_permissions = ":workspace";
        check = backend:
          checkRows "Codex sandbox model composition" {
            "a named selector cannot be loaded alongside the legacy selector" =
              failsWith "sandbox_mode/sandbox_workspace_write or default_permissions/permissions, never both"
              (evaluate backend (legacy // named));
            "an empty named catalog does not activate the named permission model" =
              failedAssertions (evaluate backend (legacy // {permissions = {};})) == [];
            "the built-in workspace selector must work without a custom catalog" =
              failedAssertions (evaluate backend named) == [];
          };
      in
        checkRows "Codex sandbox backends" {
          "Home Manager" = check evalHm;
          "devenv" = check evalDevenv;
        }
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
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.value;
        expected = config.ai.codex.native.settings;
      in
        checkRows "Codex named permission profile delivery" {
          "Home Manager preserves all declared permission rules and adds its cache root" =
            hmSettings
            == withHmDefaults (lib.recursiveUpdate expected {permissions.project-edit.filesystem."/home/test/.cache/nix" = "write";})
            && failedAssertions hm == [];
          "devenv preserves all declared permission rules without an unverified Git root" =
            devenvSettings
            == lib.recursiveUpdate expected {permissions.project-edit.filesystem."/home/test/.cache/nix" = "write";}
            && failedAssertions devenv == [];
        }
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
        project = evalDevenvWithGetEnv (_: "") {
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
        projectSettings = project.config.ai.codex.files.".codex/config.toml".content.value;
      in
        # Assert the artifacts independently. Recreating an upstream merge in
        # this test could let one layer silently supply fields the other lost.
        checkRows "Codex permission profile layers" {
          "the user layer retains its base profile and explicit deny" =
            userSettings.default_permissions
            == "project-edit"
            && userSettings.permissions
            == {
              project-edit = {
                extends = ":workspace";
                filesystem = {
                  "/home/test/.cache/nix" = "write";
                  "/tmp/shared" = "deny";
                };
                network.enabled = true;
              };
            }
            && failedAssertions user == [];
          "the project layer does not copy defaults over the inherited base profile" =
            projectSettings.default_permissions
            == "project-edit"
            && projectSettings.permissions.project-edit
            == {
              filesystem = {
                "/tmp/project-cache" = "write";
                "/tmp/shared" = "write";
              };
            }
            && failedAssertions project == [];
        }
    );

    module-codex-execpolicy-source-restrictions = mkTest "codex-execpolicy-source-restrictions" (
      let
        source = pkgs.writeText "allow-status.rules" ''prefix_rule(pattern = ["git", "status"])'';
        evaluate = backend: input:
          backend {
            ai.codex = {
              enable = true;
              execpolicyRules.probe = input;
            };
          };
        check = backend: let
          configured = evaluate backend "${source}";
          rejects = input:
            failsWith "ai.codex.execpolicyRules.probe path sources must be existing regular files or symlinks to existing files"
            (evaluate backend input);
        in
          checkRows "Codex execpolicy path source" {
            "a directory is not a regular rule file" = rejects ../../../checks/fixtures;
            "a missing absolute path cannot be delivered as a rule" = rejects "/definitely/missing/codex.rules";
            "an existing rule file remains an acceptable source" =
              failedAssertions configured == [] && (execpolicyInput configured "probe.rules").source == "${source}";
          };
      in
        checkRows "Codex execpolicy backends" {
          "Home Manager" = check evalHm;
          "devenv" = check evalDevenv;
        }
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
      rule = pkgs.writeText "git-read.rules" (execpolicyInput evaluated "git-read.rules").text;
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
        execpolicy = (execpolicyInput evaluated "command-policy.rules").text;
      in
        lib.hasInfix "Explain every command" agentsMd
        && !lib.hasInfix "prefix_rule" agentsMd
        && lib.hasInfix "prefix_rule" execpolicy
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
        hm = evalHm config;
        devenv = evalDevenv config;
        hmSource = (execpolicyInput hm "symlink-source.rules").source;
        devenvSource = (execpolicyInput devenv "symlink-source.rules").source;
      in
        fromGeneratedTree ".codex/rules/symlink-source.rules" {source = (execpolicyRule hm "symlink-source.rules").content.source;}
        && fromGeneratedTree ".codex/rules/symlink-source.rules" {source = (execpolicyRule devenv "symlink-source.rules").content.source;}
        && hmSource
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
        && (execpolicyInput devenv "default.rules").text != ""
    );

    # ── App-server daemon ───────────────────────────────────────────────────
    # Home Manager selects the package the shared daemon runs and turns off
    # upstream's updater and auto-start; devenv touches none of that and runs
    # Codex with --no-daemon. The selector's behavior against the real daemon
    # is chatgpt-codex-daemon-selection.nix; these hold the wiring.
    module-codex-daemon-hm-pins-launcher-package = mkTest "codex-daemon-hm-pins-launcher-package" (
      let
        package = aiStubs.chatgpt-codex;
        launcher = harness.aiBase.mkLauncher pkgs {
          environmentVariables.CODEX_SELECTED_LAUNCHER = "1";
          exe = "codex";
          name = "codex-selected-launcher";
          inherit package;
        };
        settings.ai.codex = {
          enable = true;
          package = launcher;
        };
        hm = evalHm settings;
        devenv = evalDevenv settings;
        packageRoot = builtins.unsafeDiscardStringContext "${package}/${package.passthru.codexPackage.root}";
      in
        lib.hasSuffix " ${packageRoot}" hm.config.ai.codex.activation.codex-daemon-select.command
        && lib.all (assertion: assertion.assertion) hm.config.assertions
        && lib.all (assertion: assertion.assertion) devenv.config.assertions
        && (builtins.head hm.config.home.packages).launcherPackage == package
        && (builtins.head devenv.config.packages).launcherPackage == package
    );

    # Declared daemon settings land beside the pin's updater default, and an
    # explicit updater choice beats it.
    module-codex-daemon-hm-settings-are-declared = mkTest "codex-daemon-hm-settings-are-declared" (
      let
        declared = evalHm {
          ai.codex = {
            enable = true;
            native.daemonSettings = {
              remoteControlEnabled = true;
              shutdownGraceSeconds = 5;
            };
          };
        };
        overridden = evalHm {
          ai.codex = {
            enable = true;
            native.daemonSettings.updater.autoUpdateEnabled = true;
          };
        };
      in
        daemonSettings declared
        == {
          remoteControlEnabled = true;
          shutdownGraceSeconds = 5;
          updater.autoUpdateEnabled = false;
        }
        && daemonSettings overridden == {updater.autoUpdateEnabled = true;}
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
          lib.hasSuffix " ''" evaluated.config.ai.codex.activation.codex-daemon-select.command
          && evaluated.config.home.activation ? ai-codex-daemon-select;
      in
        # Unpinned: the selection is released and the updater default goes,
        # while auto-start stays off; the two are independent. Home Manager
        # still owns the (empty) settings file.
        releases unpinned
        && daemonSettings unpinned == {}
        && (hmCodexSettings unpinned).features.daemon_auto_start == false
        && lib.all (assertion: assertion.assertion) unpinned.config.assertions
        && (hmCodexSettings autoStart).features.daemon_auto_start
        # Disabled: selection release still runs so it cannot outlive the managed package.
        && releases disabled
    );

    module-codex-daemon-hm-needs-package-layout = mkTest "codex-daemon-hm-needs-package-layout" (
      let
        foreign = pkgs.writeShellScriptBin "codex" "";
        evaluate = package: pinDaemonToPackage:
          evalHm {
            ai.codex = {
              enable = true;
              inherit package pinDaemonToPackage;
            };
          };
        rejectsLayout = failsWith "pinDaemonToPackage needs ai.codex.package to carry upstream's complete Codex package";
      in
        checkRows "Codex Home Manager daemon package layout" {
          "a foreign package is accepted when pinning is explicitly disabled" =
            failedAssertions (evaluate foreign false) == [];
          "pinning without upstream package metadata fails with the opt-out remedy" =
            failsWith "pinDaemonToPackage = false" (evaluate foreign true)
            && rejectsLayout (evaluate foreign true);
          # The selector only releases paths in the layout it writes.
          "pinning to an alternate root would leave a selection that cannot be released" =
            rejectsLayout (evaluate (foreign // {passthru.codexPackage.root = "opt/codex";}) true);
        }
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
        failures = extra: failedAssertions (evalDevenv {ai.codex = {enable = true;} // extra;});
        rejectsOnly = fragment: extra: let
          messages = failures extra;
        in
          builtins.length messages == 1 && lib.hasInfix fragment (builtins.head messages);
      in
        checkRows "Codex devenv daemon restrictions" {
          # Off is what --no-daemon already means, so it is accepted.
          "an explicit false is compatible with --no-daemon" =
            failures {native.settings.features.daemon_auto_start = false;} == [];
          "daemon settings cannot be delivered by a project shell" =
            rejectsOnly "native.daemonSettings is Home Manager-only" {native.daemonSettings.remoteControlEnabled = true;};
          "enabling daemon auto-start contradicts --no-daemon" =
            rejectsOnly "daemon_auto_start = true has no" {native.settings.features.daemon_auto_start = true;};
        }
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
        && lib.hasInfix "contains keys Codex ignores in project config:\nprojects." failed.message
    );

    module-codex-settings-enums-reject-invalid = mkTest "codex-settings-enums-reject-invalid" (
      let
        read = path: value:
          lib.getAttrFromPath path (hmCodexSettings (evalHm {
            ai.codex = {
              enable = true;
              native.settings = lib.setAttrByPath path value;
            };
          }));
        rejects = path: valid: invalid:
          rejectsChange (read path) {
            inherit valid invalid;
            expected = valid;
          };
        # These vocabularies come from recursive Clap help. Read back every
        # extracted member so a stale handwritten subset goes red. Separate
        # fixed controls below keep an empty extraction from passing.
        extractedFlagValues = name: let
          matches = builtins.filter (flag: builtins.elem name flag.names) codexGlobalFlags;
          matchCount = builtins.length matches;
        in
          if matchCount == 1
          then (builtins.head matches).acceptedValues
          else throw "module-eval expected exactly one extracted Codex global flag record for ${name}, found ${toString matchCount}";
        acceptsExtracted = key: flag: let
          values = extractedFlagValues flag;
        in
          values != [] && lib.all (value: read [key] value == value) values;
        permission = path: rejects (["permissions" "test"] ++ path);
      in
        checkRows "Codex native settings restrictions" {
          "approval_policy accepts the complete extracted CLI vocabulary" = acceptsExtracted "approval_policy" "--ask-for-approval";
          "approval_policy rejects sometimes" = rejects ["approval_policy"] "on-request" "sometimes";
          "approvals_reviewer rejects agent" = rejects ["approvals_reviewer"] "auto_review" "agent";
          "filesystem access rejects execute" = permission ["filesystem" ":minimal"] "read" "execute";
          "filesystem glob scan depth rejects zero" = permission ["filesystem" "glob_scan_max_depth"] 1 0;
          "known features reject strings instead of booleans" = rejects ["features" "memories"] true "yes";
          "model_reasoning_effort rejects extreme" = rejects ["model_reasoning_effort"] "max" "extreme";
          "network domain access rejects prompt" = permission ["network" "domains" "api.openai.com"] "allow" "prompt";
          "network mode rejects disabled" = permission ["network" "mode"] "limited" "disabled";
          "personality rejects verbose" = rejects ["personality"] "friendly" "verbose";
          "sandbox_mode accepts the complete extracted CLI vocabulary" = acceptsExtracted "sandbox_mode" "--sandbox";
          "sandbox_mode rejects full" = rejects ["sandbox_mode"] "workspace-write" "full";
          "unknown features also reject strings instead of booleans" = rejects ["features" "speculative_future_flag"] false "no";
          "web_search rejects enabled" = rejects ["web_search"] "live" "enabled";
        }
    );

    module-codex-project-settings-reject-ignored-keys = mkTest "codex-project-settings-reject-ignored-keys" (
      let
        config = settings: {
          ai.codex = {
            enable = true;
            native = {inherit settings;};
          };
        };
        hmOnly = {
          model_provider = "custom";
          notify = ["notify-send"];
        };
        supported = {model = "review-model";};
        hm = evalHm (config hmOnly);
        rejects = key:
          failsWith "contains keys Codex ignores in project config:\n${key}." (evalDevenv (config (supported
            // {
              ${key} = hmOnly.${key};
            })));
      in
        checkRows "Codex ignored project settings" {
          "Home Manager still delivers both user-scope settings" = hmCodexSettings hm == withHmDefaults hmOnly;
          "model_provider is ignored even without notify" = rejects "model_provider";
          "the diagnostic names all rejected settings together" =
            failsWith "contains keys Codex ignores in project config:\nmodel_provider, notify." (evalDevenv (config hmOnly));
        }
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
          codex = {
            enable = true;
            native.agents.reviewer = {
              model = "review-model";
              sandbox_mode = "read-only";
            };
          };
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
        hmAgent = agentSource hm "reviewer";
        devenvAgent = agentSource devenv "reviewer";
        claudeAgent = (markdownInput hm ".claude/agents/reviewer.md").text;
        emptyClaudeAgent = (markdownInput hm ".claude/agents/emptyTools.md").text;
        unrestrictedClaudeAgent = (markdownInput hm ".claude/agents/unrestricted.md").text;
      in
        fromGeneratedTree ".codex/agents/reviewer.toml" (deliveredFiles hm.config).".codex/agents/reviewer.toml"
        && fromGeneratedTree ".codex/agents/reviewer.toml" (deliveredFiles devenv.config).".codex/agents/reviewer.toml"
        && fromGeneratedTree ".claude/agents/reviewer.md" hm.config.home.file.".claude/agents/reviewer.md"
        && hmAgent
        == renderedAgent "reviewer" expected
        && devenvAgent == renderedAgent "reviewer" expected
        && lib.hasPrefix "---\n" claudeAgent
        && lib.hasInfix ''name: "reviewer"'' claudeAgent
        && lib.hasInfix ''description: "Review changes for correctness."'' claudeAgent
        && lib.hasInfix ''tools: "Bash, Read"'' claudeAgent
        && !(lib.hasInfix "tools:" emptyClaudeAgent)
        && lib.hasPrefix "---\n" unrestrictedClaudeAgent
        && lib.hasInfix ''description: "Review without a portable tool restriction."'' unrestrictedClaudeAgent
        && !(lib.hasInfix "tools:" unrestrictedClaudeAgent)
    );

    module-codex-agent-toml-syntax = let
      evaluated = evalHm {
        ai.codex = {
          enable = true;
          agents.reviewer = {
            description = "Review changes.";
            instructions.text = "Report concrete findings.";
          };
          native.agents.reviewer = {
            model = "review-model";
            sandbox_mode = "read-only";
          };
        };
      };
      source = (deliveredFiles evaluated.config).".codex/agents/reviewer.toml".source;
    in
      pkgs.runCommand "module-test-codex-agent-toml-syntax" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 - ${source} <<'PYTHON'
        import sys
        import tomllib

        with open(sys.argv[1], "rb") as agent_file:
            role = tomllib.load(agent_file)
        assert role == {
            "description": "Review changes.",
            "developer_instructions": "Report concrete findings.",
            "model": "review-model",
            "name": "reviewer",
            "sandbox_mode": "read-only",
        }, ("delivered role lost or changed a TOML field", role)
        PYTHON
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
        agent = agentSource result "reviewer";
      in
        fromGeneratedTree ".codex/agents/reviewer.toml" (deliveredFiles result.config).".codex/agents/reviewer.toml"
        && agent
        == renderedAgent "reviewer" {
          description = "Codex review.";
          developer_instructions = "Use Codex instructions.";
          name = "reviewer";
        }
    );

    # A native-only record (no normalized agent at its key) renders when it
    # sets the role fields itself, and one missing `developer_instructions`
    # fails an assertion that names the option, not a TOML render.
    module-codex-native-only-agent = mkTest "codex-native-only-agent" (
      let
        config.ai.codex = {
          enable = true;
          native.agents = {
            broken.description = "Missing its instructions.";
            solo = {
              description = "Native only.";
              developer_instructions = "Work alone.";
              model = "solo-model";
            };
          };
        };
        expected = {
          description = "Native only.";
          developer_instructions = "Work alone.";
          model = "solo-model";
          name = "solo";
        };
        valid = evaluated:
          agentSource evaluated "solo"
          == renderedAgent "solo" expected
          && lib.any (assertion:
            !assertion.assertion
            && lib.hasInfix "ai.codex.native.agents.broken is missing developer_instructions" assertion.message)
          evaluated.config.assertions
          && !(lib.any (assertion: !assertion.assertion && lib.hasInfix "native.agents.solo" assertion.message) evaluated.config.assertions);
      in
        valid (evalHm config) && valid (evalDevenv config)
    );

    # Force native-agent validation, not TOML generation. With a numeric
    # description the type check must throw, not yield a missing-field assertion.
    module-codex-native-agent-type-error = mkTest "codex-native-agent-type-error" (
      checkRows "Codex native agent description type" {
        "Home Manager assertions surface a numeric description's type error" = rejectsChange (description: let
          evaluated = evalHm {
            ai.codex = {
              enable = true;
              native.agents.typed = {
                inherit description;
                developer_instructions = "Typed.";
              };
            };
          };
        in
          failedAssertions evaluated == []) {
          expected = true;
          invalid = 42;
          valid = "Typed role.";
        };
      }
    );

    # A raw TOML role file, as text or a path, is delivered verbatim beside
    # the native layer, and replaces a root record at its key.
    module-codex-raw-agents = mkTest "codex-raw-agents" (
      let
        rawText = ''
          name = "rawText"
          description = "Raw text role."
          developer_instructions = "Use the raw text."
        '';
        rawPath = pkgs.writeText "raw-path.toml" ''
          name = "rawPath"
          description = "Raw path role."
          developer_instructions = "Use the raw path."
        '';
        config.ai = {
          agents.rawText = {
            description = "Root record.";
            instructions.text = "Replaced by the raw file.";
          };
          codex = {
            enable = true;
            agents = {inherit rawPath rawText;};
          };
        };
        valid = evaluated: let
          files = evaluated.config.ai.codex._generatedFiles;
        in
          files.".codex/agents/rawText.toml".content.text
          == rawText
          && files.".codex/agents/rawPath.toml".content.source == toString rawPath
          && !(evaluated.config.ai.codex.native.agents ? rawText)
          && !(evaluated.config.ai.codex.native.agents ? rawPath)
          && builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions == [];
      in
        valid (evalHm config) && valid (evalDevenv config)
    );

    # Codex's `agentsDir` expands `.toml` role files into raw entries and
    # skips every other file.
    module-codex-agents-dir = mkTest "codex-agents-dir" (
      let
        config.ai.codex = {
          enable = true;
          agentsDir = ./fixtures/codex-agents-dir;
        };
        valid = evaluated: let
          files = evaluated.config.ai.codex._generatedFiles;
        in
          files.".codex/agents/reviewer.toml".content.source
          == ./fixtures/codex-agents-dir/reviewer.toml
          && !(lib.any (lib.hasInfix "notes") (builtins.attrNames files));
      in
        valid (evalHm config) && valid (evalDevenv config)
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
        };
        agentServers.mcp_servers."tracker.dotted" = remote {inherit oauth;};
        pooled.ai = {
          agents.reviewer = reviewAgent;
          codex = {
            enable = true;
            agents.auditor = reviewAgent;
            native.agents = {
              auditor = agentServers;
              reviewer = agentServers;
            };
            mcpServers = {
              "local.dotted" = remote {codex.oauth = oauth;};
              replaced = remote {codex.oauth.client_id = "public-client";};
            };
          };
          mcpServers = {
            replaced = remote {codex.oauth = oauth;};
            "shared.dotted" = remote {codex.oauth = oauth;};
          };
        };
        native.ai.codex = {
          enable = true;
          native.settings.mcp_servers."direct.dotted" = remote {inherit oauth;};
        };
        secretFailures = result:
          builtins.filter (assertion:
            !assertion.assertion
            && lib.hasInfix ".oauth.client_secret cannot be set:" assertion.message)
          result.config.assertions;
        # Every route retains the shared credential reason and quotes dotted
        # names as one segment. Agent tables get the role-layer remedy, server
        # tables the Nix-managed credential routes; never the other's, and
        # neither points at a runtime `codex mcp` command, since Nix owns MCP
        # configuration.
        rejectsExactly = paths: result: let
          failures = secretFailures result;
        in
          builtins.length failures
          == builtins.length (builtins.attrNames paths)
          && lib.all lib.id (lib.mapAttrsToList (path: remedy:
            builtins.any (assertion:
              lib.hasPrefix "${path}.oauth.client_secret cannot be set: secret fields carry confidential authentication material." assertion.message
              && lib.hasSuffix "." assertion.message
              && lib.hasInfix "world-readable Nix store" assertion.message
              && lib.hasInfix "environment-variable or file reference" assertion.message
              && lib.hasInfix remedy assertion.message
              && lib.all (part: lib.hasInfix part assertion.message) (
                if remedy == agentRemedy
                then ["ai.mcpServers or ai.codex.mcpServers" "without a client secret"]
                else ["codex.bearerTokenEnvVar" "codex.envHttpHeaders" "Home Manager's local credential" "proxy.headers"]
              )
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
        serverRemedy = "set proxy.enable with";
        pooledPaths = {
          "ai.codex.mcpServers.\"local.dotted\".codex" = serverRemedy;
          "ai.codex.native.agents.auditor.mcp_servers.\"tracker.dotted\"" = agentRemedy;
          "ai.codex.native.agents.reviewer.mcp_servers.\"tracker.dotted\"" = agentRemedy;
          "ai.mcpServers.\"shared.dotted\".codex" = serverRemedy;
        };
        nativePaths."ai.codex.native.settings.mcp_servers.\"direct.dotted\"" = serverRemedy;
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
        && devenv.config.ai.codex.files.".codex/config.toml".content.value.mcp_servers.remote == expected
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
        devenvAgents = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.value.agents;
      in
        checkRows "Codex agent defaults delivery" {
          "Home Manager retains every declared agent default, including enabled" = hmAgents == config.ai.codex.native.settings.agents;
          "devenv retains every declared agent default, including enabled" = devenvAgents == config.ai.codex.native.settings.agents;
        }
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
        expected.hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                command = lib.getExe pkgs.hello;
                type = "command";
              }
            ];
          }
          {
            matcher = "apply_patch";
            hooks = [
              {
                additionalContextLimit = 0;
                command = "review-patch";
                commandWindows = "review-patch.exe";
                statusMessage = "Reviewing patch";
                timeout = 30;
                type = "command";
              }
            ];
          }
        ];
        input = evaluated: evaluated.config.ai.codex._generatedFiles.".codex/hooks.json".content.source;
        json = pkgs.formats.json {};
        claudeBlocks = (claudeSettings hm).hooks.PreToolUse;
      in
        input hm
        == toString (json.generate "codex-hooks.json" expected)
        && input devenv == toString (json.generate "codex-project-hooks.json" expected)
        && fromGeneratedTree ".codex/hooks.json" (deliveredFiles hm.config).".codex/hooks.json"
        && fromGeneratedTree ".codex/hooks.json" (deliveredFiles devenv.config).".codex/hooks.json"
        && builtins.length claudeBlocks == 1
        && (builtins.head claudeBlocks).matcher == "Bash"
    );

    module-codex-hooks-inline-source-collision-fails = mkTest "codex-hooks-inline-source-collision-fails" (
      let
        evaluate = withInline:
          evalHm {
            ai.codex = {
              enable = true;
              hooks.Stop = [{hooks = [{command = "validate";}];}];
              native.settings = lib.optionalAttrs withInline {hooks.Stop = [{hooks = [{command = "legacy";}];}];};
            };
          };
      in
        checkRows "Codex hook source exclusivity" {
          "hooks.json alone does not conflict with an absent inline event" = failedAssertions (evaluate false) == [];
          "an inline event cannot coexist with hooks.json fanout" =
            failsWith "cannot be combined with inline hook events in ai.codex.native.settings.hooks" (evaluate true);
        }
    );

    # Nix declares the trust of every generated hook, because `/hooks` cannot
    # write the Nix-owned user config.toml (see `hookTrustFor` in mkCodex.nix).
    # The two hashes are the ones codex-cli 0.157.1's `hooks/list` reported for
    # these handlers; chatgpt-codex-hook-trust compares every derived value
    # with the pinned binary. Home Manager writes the state into user
    # config.toml beside any declared `hooks.state`; devenv's launcher passes
    # it as one `-c` session flag, and project config may not carry it,
    # because Codex ignores hook trust there.
    module-codex-hooks-trust-is-declared = let
      config.ai = {
        codex = {
          enable = true;
          hooks.Stop = [{hooks = [{command = "echo stop";}];}];
        };
        hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                command = "echo hi";
                timeout = 5;
              }
            ];
          }
        ];
      };
      preToolUse = "sha256:b98dab5eee824a2bcfee70e81c0883e7226870b4c205cfe7fcd34b86d81322e0";
      stop = "sha256:236335e9e512004a0f5f42af65a07ea9059bd9a23dbb68286ed57fecf2b69ddf";
      hm = evalHm (lib.recursiveUpdate config {
        ai.codex.native.settings.hooks.state."/plugin/hooks.json:stop:0:0".trusted_hash = "sha256:declared";
      });
      devenv = evalDevenv config;
      devenvStateFailures =
        lib.filter (assertion: !assertion.assertion)
        (evalDevenv (lib.recursiveUpdate config {
          ai.codex.native.settings.hooks.state."/plugin/hooks.json:stop:0:0".trusted_hash = "sha256:declared";
        }))
        .config
        .assertions;
    in
      assert (hmCodexSettings hm).hooks
      == {
        state = {
          "/home/test/.codex/hooks.json:pre_tool_use:0:0".trusted_hash = preToolUse;
          "/home/test/.codex/hooks.json:stop:0:0".trusted_hash = stop;
          "/plugin/hooks.json:stop:0:0".trusted_hash = "sha256:declared";
        };
      };
      assert lib.all (assertion: assertion.assertion) hm.config.assertions;
      # hooks.state travels only in session flags on devenv.
      assert !(devenv.config.ai.codex.files ? ".codex/config.toml");
      assert builtins.length devenvStateFailures == 1;
      assert hasLiteral "hooks.state has no effect in project" (lib.head devenvStateFailures).message;
        mkWrapperGrepTest {
          name = "codex-hooks-trust-is-declared";
          package = lib.head devenv.config.packages;
          bin = "codex";
          needles = [
            "'hooks.state={\"/tmp/devenv-root/.codex/hooks.json:pre_tool_use:0:0\" = {\"trusted_hash\" = \"${preToolUse}\"}, \"/tmp/devenv-root/.codex/hooks.json:stop:0:0\" = {\"trusted_hash\" = \"${stop}\"}}'"
          ];
        };

    module-codex-hooks-json-syntax = let
      evaluated = evalDevenv {
        ai.codex = {
          enable = true;
          hooks.Stop = [{hooks = [{command = "validate";}];}];
        };
      };
      source = (deliveredFiles evaluated.config).".codex/hooks.json".source;
    in
      pkgs.runCommand "module-test-codex-hooks-json-syntax" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.jq}/bin/jq -e '. == {hooks: {Stop: [{hooks: [{type: "command", command: "validate"}]}]}}' ${source}
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
        && (markdownInput devenv "AGENTS.md").text
        == builtins.concatStringsSep "\n\n" [
          "<!-- rule: alpha -->\n\nApply this rule only in: `codex`.\n\nAlpha rule"
          "<!-- rule: zeta -->\n\nApply this rule only in: `codex`.\n\nZeta rule"
          "Shared context"
          "Codex context"
        ]
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
        rejectsPath = invalid:
          rejectsChange (configDir:
            (evalHm {
              ai.codex = {
                inherit configDir;
                enable = true;
              };
            }).config.ai.codex.configDir) {
            valid = ".config/codex";
            inherit invalid;
            expected = ".config/codex";
          };
      in
        checkRows "Codex configuration directory" {
          "absolute paths escape HOME" = rejectsPath "/tmp/codex";
          "an empty path selects HOME itself" = rejectsPath "";
          "an interior parent segment must not pass a leading-only check" = rejectsPath "config/../codex";
          "a leading parent segment escapes HOME" = rejectsPath "../codex";
        }
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
        && (markdownInput devenv "AGENTS.md").text
        == "<!-- rule: scoped -->\n\nApply this rule only in: `codex`.\n\n_Apply this guidance only when working with files matching: `src/**`_\n\nScoped rule"
    );

    # A scoped rule that names the documents holding its text is listed, not
    # inlined: the flat file carries its globs and links, never its body. An
    # unscoped rule with references stays inline, because an index entry with
    # no globs could never tell the reader when to follow it.
    # Distinct source directories keep this a direct root-index fixture;
    # shared child-index delivery has its own ai-context checks.
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
                references = ["beta/b.md"];
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
            + "- **`beta`**\n  - Match:\n    - `b/**`\n  - Read:\n    - [`beta/b.md`](beta/b.md)\n"
          )
          "<!-- rule: always -->\n\nAlways body"
          "Shared context"
        ];
      in
        (markdownInput hm ".codex/AGENTS.md").text
        == expected
        && (markdownInput devenv "AGENTS.md").text
        == builtins.concatStringsSep "\n\n" [
          (
            "## Path-scoped rules\n\n"
            + "Before editing a path that matches an entry below, read every document listed\n"
            + "for it. When several entries match, their guidance composes.\n\n"
            + "This fallback index applies only to: `codex`.\n"
            + "Runtimes with native rule injection already receive their applicable\n"
            + "rules; do not follow this fallback index to load additional guidance.\n"
            + "If your runtime is not named, skip this index.\n\n"
            + "- **`alpha`**\n  - Match:\n    - `a/**`\n    - `lib/a.nix`\n"
            + "  - Read:\n    - [`docs/a.md`](docs/a.md)\n    - [`docs/a-more.md`](docs/a-more.md)\n"
            + "- **`beta`**\n  - Match:\n    - `b/**`\n  - Read:\n    - [`beta/b.md`](beta/b.md)\n"
          )
          "<!-- rule: always -->\n\nApply this rule only in: `codex`.\n\nAlways body"
          "Shared context"
        ]
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

    # Codex's limit is checked on the built file in the tree that delivers it.
    # Home Manager keys generated content by `.codex/AGENTS.md`. The boundary arithmetic is covered by
    # `checks/markdown/markdown-byte-limit-scripts.nix`.
    module-codex-agents-md-byte-limit = let
      path = ".codex/AGENTS.md";
      hint = "Trim or replace the final content, or raise ai.codex.projectDocMaxBytes.";
      boundary = size:
        evalHm {
          ai.codex = {
            enable = true;
            context.text = lib.concatStrings (lib.replicate (size - 1) "x") + "\n";
          };
        };
      treeFor = evaluated: deliveredTree evaluated path;
      exact = boundary 32768;
      above = boundary 32769;
      failure = pkgs.testers.testBuildFailure (treeFor above);
    in
      pkgs.runCommand "module-test-codex-agents-md-byte-limit" {} ''
        test -f ${treeFor exact}/${path}
        grep -q -F ${lib.escapeShellArg "${path} renders to 32769 bytes, exceeding its limit (32768 bytes). ${hint}"} ${failure}/testBuildFailure.log
        echo PASS > "$out"
      '';

    # Both backends' launchers run the project-config notices against the
    # launch directory, so they reach Home Manager-only users in any repo.
    module-codex-launch-config-notices = let
      stub = pkgs.writeShellScriptBin "codex" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
      '';
      launchers = map (launcher: "${launcher}/bin/codex") [
        (lib.head
          (evalHm {
            ai.codex = {
              enable = true;
              package = stub;
              pinDaemonToPackage = false;
            };
          }).config.home.packages)
        (lib.head
          (evalDevenv {
            ai.codex = {
              enable = true;
              package = stub;
            };
          }).config.packages)
      ];
    in
      pkgs.runCommand "module-test-codex-launch-config-notices" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Each run gets its own project and Codex home.
        isolated() {
          work="$(${pkgs.coreutils}/bin/mktemp -d)"
          TMPDIR="$work" CODEX_HOME="$work/user" ${pkgs.python3}/bin/python3 "$@"
        }
        for launcher in ${lib.escapeShellArgs launchers}; do
          isolated ${./permission-layers-notice-test.py} "$launcher"
          isolated ${./project-trust-notice-test.py} "$launcher" ${lib.getExe (import ../lib/effectiveProjectDocMaxBytes.nix pkgs)} ${pkgs.git}/bin/git
        done
        echo PASS > "$out"
      '';

    # Consumer raw replacements retain their spaces and bypass tree guards.
    module-codex-raw-agents-md-overrides-are-verbatim = let
      text = "RAW   REPLACEMENT\n";
      evaluate = backend:
        (
          if backend == "hm"
          then evalHm
          else evalDevenv
        ) {
          ai.codex = {
            enable = true;
            files.${
              if backend == "hm"
              then ".codex/AGENTS.md"
              else "AGENTS.md"
            } = {
              content.text = text;
              format = "raw";
            };
            projectDocMaxBytes = 16;
          };
        };
      sources = map (backend: let
        evaluated = evaluate backend;
        path =
          if backend == "hm"
          then ".codex/AGENTS.md"
          else "AGENTS.md";
      in
        assert evaluated.config.ai.files.${path}.format == "raw";
          (deliveredFiles
            evaluated.config).${
            path
          }.source or (
            pkgs.writeText "delivered-raw-agents-md" (deliveredFiles evaluated.config).${path}.text
          )) ["hm" "devenv"];
      expected = pkgs.writeText "raw-agents-md" text;
    in
      pkgs.runCommand "module-test-codex-raw-agents-md-overrides-are-verbatim" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.concatMapStringsSep "\n" (source: "${pkgs.diffutils}/bin/cmp -- ${source} ${expected}") sources}
        ${pkgs.coreutils}/bin/touch "$out"
      '';

    # The shared AGENTS.md carries the limit of every runtime that reads it,
    # whoever supplies the content: here Codex's limit, and Kiro's rule alone.
    # The internal tree is built with that limit and fails past it.
    module-codex-shared-byte-limit-covers-kiro-only-content = let
      hint = "Trim the contributing context or rules, replace the final file, or raise the runtime's document-size limit.";
      oversized = evalDevenv {
        ai = {
          codex = {
            enable = true;
            projectDocMaxBytes = 16;
          };
          kiro = {
            cli.enable = true;
            rules.kiro-only.text = lib.concatStrings (lib.replicate 32 "x");
          };
        };
      };
      empty = evalDevenv {ai.codex.enable = true;};
      tree = deliveredTree oversized "AGENTS.md";
      failure = pkgs.testers.testBuildFailure tree;
    in
      assert lib.assertMsg (oversized.config.ai.internal.agentsMd."AGENTS.md".maxBytes == 16)
      "codex-shared-byte-limit-covers-kiro-only-content: shared AGENTS.md does not carry Codex's byte limit";
      assert lib.assertMsg (!((deliveredFiles empty.config) ? "AGENTS.md"))
      "codex-shared-byte-limit-covers-kiro-only-content: a limit alone delivered an AGENTS.md";
        pkgs.runCommand "module-test-codex-shared-byte-limit-covers-kiro-only-content" {} ''
          grep -q -F ${lib.escapeShellArg "AGENTS.md renders to"} ${failure}/testBuildFailure.log
          grep -q -F ${lib.escapeShellArg hint} ${failure}/testBuildFailure.log
          echo PASS > "$out"
        '';
  };
}
