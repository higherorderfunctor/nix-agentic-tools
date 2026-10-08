# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiStubs claudeSettings deliveredFiles deliveredTree evalDevenv evalDevenvWithGetEnv evalDevenvWithSpecialArgs evalHm fromGeneratedTree hasLiteral markdownInput mkTest mkWrapperGrepTest ownPlan tomlFormat windowNoticeLines;
  # The daemon's settings.json is a read-only copy in the one directory target
  # of Home Manager's daemon-settings writer. `ownPlan` throws on an absent
  # writer, so a renamed entry fails the check.
  daemonSettingsTarget = evaluated: lib.head (ownPlan "codex" "materialize-codex-daemon-settings" evaluated).targets;
  # The declared JSON, or null when the writer claims no file.
  daemonSettings = evaluated: let
    path = "${evaluated.config.ai.codex.configDir}/app-server-daemon/settings.json";
  in
    if evaluated.config.ai.codex.files ? ${path}
    then evaluated.config.ai.codex.files.${path}.content.value
    else null;
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
  execpolicyInput = evaluated: name: markdownInput evaluated ".codex/rules/${name}";
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) codexExtracted hmCodexSettings withHmDaemonDefault;
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

    # `pinDaemonToPackage` is declared under `hm.options` only: devenv's
    # backend option tree does not carry it at all, so setting it there is an
    # unknown-option evaluation error, not a rejected value.
    module-codex-pinDaemonToPackage-devenv-unknown-option = mkTest "codex-pinDaemonToPackage-devenv-unknown-option" (!(builtins.tryEval (builtins.deepSeq
      (evalDevenv {
        ai.codex = {
          enable = true;
          pinDaemonToPackage = false;
        };
      })
          .config
      true))
      .success);

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
          }).config.ai.codex.files.".codex/config.toml".content.value.sandbox_workspace_write.writable_roots;
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
        fromGeneratedTree ".agents/skills/local" hm.config.home.file.".agents/skills/local"
        && (markdownInput hm ".agents/skills/local").source == ../../claude-code/checks/fixtures/claude-skills/skill-b
        && !(hm.config.home.file.".agents/skills/local" ? recursive)
        && fromGeneratedTree ".agents/skills/shared" hm.config.home.file.".agents/skills/shared"
        && (markdownInput hm ".agents/skills/shared").source == ../../claude-code/checks/fixtures/claude-skills/skill-a
        && !(hm.config.home.file.".agents/skills/shared" ? recursive)
        && fromGeneratedTree ".agents/skills/local" devenv.config.files.".agents/skills/local"
        && (markdownInput devenv ".agents/skills/local").source == ../../claude-code/checks/fixtures/claude-skills/skill-b
        && fromGeneratedTree ".agents/skills/shared" devenv.config.files.".agents/skills/shared"
        && (markdownInput devenv ".agents/skills/shared").source == ../../claude-code/checks/fixtures/claude-skills/skill-a
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
      source = (deliveredFiles evaluated.config).".agents/skills/single".source;
    in
      assert fromGeneratedTree ".agents/skills/single" evaluated.config.home.file.".agents/skills/single";
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
        fromGeneratedTree ".agents/skills/duplicate" evaluated.config.home.file.".agents/skills/duplicate"
        && (markdownInput evaluated ".agents/skills/duplicate").source == ../../claude-code/checks/fixtures/claude-skills/skill-b
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
        && devenv.config.ai.codex.files.".codex/config.toml".content.value == expected
    );

    # config.toml is a plain store symlink on both backends: no writer owns
    # it and no fact says Codex writes it, because every Codex config writer
    # fails against the link (chatgpt-codex-readonly-config).
    module-codex-config-toml-is-a-store-symlink = mkTest "codex-config-toml-is-a-store-symlink" (
      let
        config.ai.codex = {
          enable = true;
          native.settings.model = "declared";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        ownedPaths = evaluated:
          lib.concatMap (record:
            lib.concatMap (target: [target.path] ++ map (unit: "${target.path}/${unit}") (builtins.attrNames (target.units or {})))
            record.plan.targets)
          (builtins.attrValues evaluated.config.ai.codex._ownPlans);
        unowned = evaluated: !lib.any (lib.hasSuffix "config.toml") (ownedPaths evaluated);
      in
        hm.config.home.file ? ".codex/config.toml"
        && devenv.config.files ? ".codex/config.toml"
        && unowned hm
        && unowned devenv
        && !hm.config.ai.codex.files.".codex/config.toml".facts.harnessWrites
        && !devenv.config.ai.codex.files.".codex/config.toml".facts.harnessWrites
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
            features.daemon_auto_start = null;
            model = null;
            model_reasoning_effort = null;
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
        && devenv.config.ai.codex.files.".codex/config.toml".content.value.mcp_servers == expected
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
        devenvServer = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.value.mcp_servers.context7-mcp;
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
            git-intel-mcp.package = pkgs.hello;
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
        devenvServers = (evalDevenv config).config.ai.codex.files.".codex/config.toml".content.value.mcp_servers;
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
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.value;
      in
        hmCodexSettings hm
        == withHmDaemonDefault expected
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
        devenv = evalDevenv config;
        hmSettings = hmCodexSettings hm;
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.value;
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
        devenvSettings = devenv.config.ai.codex.files.".codex/config.toml".content.value;
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
        projectSettings = project.config.ai.codex.files.".codex/config.toml".content.value;
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
        hm = evalHm config;
        devenv = evalDevenv config;
        hmRule = (execpolicyInput hm "git-read.rules").text;
        devenvRule = (execpolicyInput devenv "git-read.rules").text;
      in
        fromGeneratedTree ".codex/rules/git-read.rules" {source = (execpolicyUnits hm)."git-read.rules".store;}
        && fromGeneratedTree ".codex/rules/git-read.rules" {source = (execpolicyUnits devenv)."git-read.rules".store;}
        && hmRule
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

    module-codex-execpolicy-string-store-path-is-source = mkTest "codex-execpolicy-string-store-path-is-source" (
      let
        rule = pkgs.writeText "string-source.rules" ''prefix_rule(pattern = ["git", "status"])'';
        config.ai.codex = {
          enable = true;
          execpolicyRules.string-source = "${rule}";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmSource = (execpolicyInput hm "string-source.rules").source;
        devenvSource = (execpolicyInput devenv "string-source.rules").source;
      in
        fromGeneratedTree ".codex/rules/string-source.rules" {source = (execpolicyUnits hm)."string-source.rules".store;}
        && fromGeneratedTree ".codex/rules/string-source.rules" {source = (execpolicyUnits devenv)."string-source.rules".store;}
        && hmSource
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
        hm = evalHm config;
        devenv = evalDevenv config;
        hmSource = (execpolicyInput hm "symlink-source.rules").source;
        devenvSource = (execpolicyInput devenv "symlink-source.rules").source;
      in
        fromGeneratedTree ".codex/rules/symlink-source.rules" {source = (execpolicyUnits hm)."symlink-source.rules".store;}
        && fromGeneratedTree ".codex/rules/symlink-source.rules" {source = (execpolicyUnits devenv)."symlink-source.rules".store;}
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
        && daemonSettings hm == {updater.autoUpdateEnabled = false;}
        && (daemonSettingsTarget hm).path == ".codex/app-server-daemon"
        && (hmCodexSettings hm).features.daemon_auto_start == false
        && lib.all (assertion: assertion.assertion) hm.config.assertions
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
          hasLiteral "/bin/codex-daemon-select \"$HOME\"/.codex ''\n" evaluated.config.home.activation.codexDaemonSelect.text;
      in
        # Unpinned: the selection is released and the updater default goes,
        # while auto-start stays off; the two are independent. Home Manager
        # still owns the (empty) settings file.
        releases unpinned
        && daemonSettings unpinned == {}
        && (hmCodexSettings unpinned).features.daemon_auto_start == false
        && lib.all (assertion: assertion.assertion) unpinned.config.assertions
        && (hmCodexSettings autoStart).features.daemon_auto_start
        # Disabled: both writers still run, so a store selection cannot
        # outlive the package that GC removes, and the copy is retracted.
        && releases disabled
        && (daemonSettingsTarget disabled).units == {}
        && (daemonSettingsTarget disabled).ledger == (daemonSettingsTarget unpinned).ledger
        && lib.all (entry: disabled.config.home.activation ? ${entry}) ["materialize-codex-daemon-settings" "materialize-codex-daemon-settings-prune"]
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
        declared = failures {
          ai.codex = {
            enable = true;
            native.daemonSettings.remoteControlEnabled = true;
          };
        };
      in
        builtins.length autoStart
        == 1
        && hasLiteral "daemon_auto_start = true has no" (lib.head autoStart)
        && builtins.length declared == 1
        && hasLiteral "native.daemonSettings is Home Manager-only" (lib.head declared)
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
        && lib.hasInfix ''tools: "Bash, Read"'' claudeAgent
        && !(lib.hasInfix "tools:" emptyClaudeAgent)
        && !(lib.hasInfix "tools:" emptyCopilotAgent)
        && lib.hasPrefix "---\n" unrestrictedClaudeAgent
        && lib.hasInfix ''description: "Review without a portable tool restriction."'' unrestrictedClaudeAgent
        && !(lib.hasInfix "tools:" unrestrictedClaudeAgent)
        && lib.hasInfix "Read first, then report concrete findings." copilotAgent
        && lib.hasInfix ''tools: "Bash, Read"'' copilotAgent
        && !(lib.hasInfix "name:" copilotAgent)
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
      assert fromGeneratedTree ".codex/agents/reviewer.toml" evaluated.config.home.file.".codex/agents/reviewer.toml";
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
          evaluated.config.ai.codex.files.".codex/agents/solo.toml".content.source.value
          == expected
          && lib.any (assertion:
            !assertion.assertion
            && lib.hasInfix "ai.codex.native.agents.broken is missing developer_instructions" assertion.message)
          evaluated.config.assertions
          && !(lib.any (assertion: !assertion.assertion && lib.hasInfix "native.agents.solo" assertion.message) evaluated.config.assertions);
      in
        valid (evalHm config) && valid (evalDevenv config)
    );

    # A wrong-typed role field fails with its type error. It must not be
    # reported as missing: that message would hide the real one.
    module-codex-native-agent-type-error = mkTest "codex-native-agent-type-error" (
      let
        config.ai.codex = {
          enable = true;
          native.agents.typed = {
            description = 42;
            developer_instructions = "Typed.";
          };
        };
        fails = evaluated: !(builtins.tryEval (builtins.deepSeq (map (assertion: assertion.assertion) evaluated.config.assertions) true)).success;
      in
        fails (evalHm config) && fails (evalDevenv config)
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
          files = evaluated.config.ai.codex.files;
        in
          files.".codex/agents/rawText.toml".content.text
          == rawText
          && files.".codex/agents/rawPath.toml".content.source == rawPath
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
          files = evaluated.config.ai.codex.files;
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
        agentServers.mcp_servers.tracker = remote {inherit oauth;};
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
          "ai.codex.native.agents.auditor.mcp_servers.tracker" = agentRemedy;
          "ai.codex.native.agents.reviewer.mcp_servers.tracker" = agentRemedy;
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
          && lib.hasInfix "cannot be combined with inline hook events in ai.codex.native.settings.hooks" assertion.message)
        result.config.assertions
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
      assert !(devenv.config.ai.codex.files.".codex/config.toml".content.value ? hooks);
      assert builtins.length devenvStateFailures == 1;
      assert hasLiteral "hooks.state has no effect in project" (lib.head devenvStateFailures).message;
        mkWrapperGrepTest {
          name = "codex-hooks-trust-is-declared";
          package = lib.head devenv.config.packages;
          bin = "codex";
          needles = [
            "'hooks.state={\"/tmp/devenv-root/.codex/hooks.json:pre_tool_use:0:0\" = {trusted_hash = \"${preToolUse}\"}, \"/tmp/devenv-root/.codex/hooks.json:stop:0:0\" = {trusted_hash = \"${stop}\"}}'"
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
      assert fromGeneratedTree ".codex/hooks.json" evaluated.config.files.".codex/hooks.json";
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
        && !devenv.config.ai.internal.agentsMd."AGENTS.md".hasOnDemandIndex
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

    # Codex's limit is checked on the built file in the tree that delivers it.
    # Home Manager keys it by `.codex/AGENTS.md`, so replacements and generated
    # content carry the same limit. The boundary arithmetic is covered by
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
      treeFor = evaluated: deliveredTree evaluated path;
      exact = replaced 32768;
      above = replaced 32769;
      failure = pkgs.testers.testBuildFailure (treeFor above);
    in
      assert lib.assertMsg (generated.config.ai.codex._maxBytes == limit && exact.config.ai.codex._maxBytes == limit)
      "codex-agents-md-byte-limit: ai.codex._maxBytes is not the 32768-byte limit on ${path}";
      assert lib.assertMsg (lib.all (evaluated: fromGeneratedTree path evaluated.config.home.file.${path}) [generated exact above])
      "codex-agents-md-byte-limit: ${path} is not delivered from a tree carrying its limit";
        pkgs.runCommand "module-test-codex-agents-md-byte-limit" {} ''
          test -f ${treeFor exact}/${path}
          grep -q -F ${lib.escapeShellArg "${path} renders to 32769 bytes, exceeding its limit (32768 bytes). ${hint}"} ${failure}/testBuildFailure.log
          echo PASS > "$out"
        '';

    module-codex-project-trust-notice = let
      linesOf = evaluated: lib.filter (lib.hasInfix "/bin/codex-project-trust-notice ") (lib.splitString "\n" evaluated.config.enterShell);
      enabled = evalDevenv {ai.codex.enable = true;};
      suppressed = evalDevenv {
        ai.codex = {
          enable = true;
          files.".codex/config.toml".content.enable = false;
        };
      };
    in
      assert builtins.length (linesOf enabled) == 1;
      assert linesOf (evalDevenv {}) == [] && linesOf suppressed == [];
      assert linesOf (evalDevenv {
        ai.codex = {
          enable = true;
          native.settings = {
            model = null;
            model_reasoning_effort = null;
          };
        };
      })
      == [];
        pkgs.runCommand "module-test-codex-project-trust-notice" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export CODEX_HOME="$TMPDIR/user"
          ${pkgs.python3}/bin/python3 ${./project-trust-notice-test.py} ${pkgs.writeShellScript "rendered-codex-project-trust-notice" ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            ${lib.head (linesOf enabled)}
          ''} ${lib.getExe (import ../lib/effectiveProjectDocMaxBytes.nix pkgs)} ${pkgs.git}/bin/git
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
        expected = ["${lib.getExe (import ../../../lib/markdown/byte-limit.nix pkgs).windowNotice} \"$DEVENV_ROOT\"/${lib.escapeShellArgs ["AGENTS.md" "32768" "codex" (lib.getExe (import ../lib/effectiveProjectDocMaxBytes.nix pkgs))]}"];
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
      cases = {
        hm = evaluated: {
          delivered = evaluated.config.home.file.".codex/AGENTS.md".source;
          path = ".codex/AGENTS.md";
        };
        devenv = evaluated: {
          delivered = (deliveredFiles evaluated.config)."AGENTS.md".source;
          path = "AGENTS.md";
        };
      };
      checked = backend: evaluated: let
        case = cases.${backend} evaluated;
        tree = deliveredTree evaluated case.path;
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
      tree = deliveredTree oversized "AGENTS.md";
      failure = pkgs.testers.testBuildFailure tree;
    in
      assert lib.assertMsg (oversized.config.ai.internal._maxBytes == limit)
      "codex-shared-byte-limit-covers-kiro-only-content: ai.internal._maxBytes is not Codex's limit on AGENTS.md";
      assert lib.assertMsg (fromGeneratedTree "AGENTS.md" (deliveredFiles oversized.config)."AGENTS.md")
      "codex-shared-byte-limit-covers-kiro-only-content: AGENTS.md is not delivered from a tree carrying its limit";
      assert lib.assertMsg (!((deliveredFiles empty.config) ? "AGENTS.md"))
      "codex-shared-byte-limit-covers-kiro-only-content: a limit alone delivered an AGENTS.md";
        pkgs.runCommand "module-test-codex-shared-byte-limit-covers-kiro-only-content" {} ''
          grep -q -F ${lib.escapeShellArg "AGENTS.md renders to"} ${failure}/testBuildFailure.log
          grep -q -F ${lib.escapeShellArg hint} ${failure}/testBuildFailure.log
          echo PASS > "$out"
        '';

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
