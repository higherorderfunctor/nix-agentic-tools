# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm mkTest ownPlan ownedDocument;
  kimchiDocument = path: ownedDocument "kimchi" path;
  hmConfigDocument = evaluated: kimchiDocument "${evaluated.config.ai.kimchi.configDir}/config.json" evaluated;
  hmHarnessDocument = evaluated: kimchiDocument "${evaluated.config.ai.kimchi.configDir}/harness/settings.json" evaluated;
  projectConfigDocument = kimchiDocument ".kimchi/config.json";
  projectHarnessDocument = kimchiDocument ".config/kimchi/harness/settings.json";
  projectMcpDocument = kimchiDocument ".kimchi/mcp.json";
  hmMcpDocument = evaluated: kimchiDocument "${evaluated.config.ai.kimchi.configDir}/harness/mcp.json" evaluated;
  # The keys come from the sidecar; each needs a sample value here, so a key
  # that becomes user-scope fails evaluation until someone adds one.
  userScopeOnlyHarnessSettingKeys =
    (import ../lib/extracted.nix {
      inherit lib pkgs;
      extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
    }).userScopeHarnessKeys;
  userScopeOnlyHarnessSettingValues = {
    autoDefaultApplied = true;
    defaultProjectTrust = "always";
    fermentV2.autoResume = true;
    hidePhaseChanges = true;
    httpProxy = "http://proxy.invalid:3128";
    lastTerminalWarnings.kitty = "0.35.0";
    modelMetadata.example.description = "Example model";
    modelRoles.builder = "provider/model";
    multiModel = true;
    resources."tools.web_search" = true;
    shellProfileApiKeyMigrationDismissed = true;
    statusLine.pinned = ["model"];
  };
  kimchiStub = pkgs.writeShellScriptBin "kimchi" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
  exactCwdProjectRoot = pkgs.runCommand "kimchi-exact-cwd-project-root" {} ''
    mkdir -p "$out/subdir"
  '';

  mkDevenvKimchiPackage = extraConfig:
    builtins.head
    (evalDevenv (lib.recursiveUpdate {
        devenv.root = toString exactCwdProjectRoot;
        ai.kimchi = {
          enable = true;
          package = kimchiStub;
        };
      }
      extraConfig)).config.packages;

  # Agents: one portable record from the root pool and one Kimchi-native
  # Markdown file from the runtime pool, on both backends.
  nativeAgent = ''
    ---
    description: native
    tools: read, grep
    ---

    NATIVE
  '';
  agentConfig.ai = {
    agents.reviewer = {
      description = "Reviews code";
      instructions.text = "BODY";
    };
    kimchi = {
      enable = true;
      agents.native = nativeAgent;
    };
  };
  # The units one agents writer owns, read from the plan it applies.
  agentUnits = entry: dir: evaluated:
    (lib.head (lib.filter (target: target.codec == "dir" && target.path == dir)
        (ownPlan "kimchi" entry evaluated).targets))
    .units;
  hmAgentUnits = agentUnits "kimchiAgents" ".config/kimchi/harness/agents";
  devenvAgentUnits = agentUnits "ai:kimchi:agents" ".kimchi/agents";
  failedAssertions = evaluated: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) evaluated.config.assertions);

  checkModuleAssertions = evaluated: let
    failed = builtins.filter (entry: !entry.assertion) evaluated.config.assertions;
  in
    if failed == []
    then evaluated.config.files
    else throw (lib.concatMapStringsSep "\n" (entry: entry.message) failed);

  userScopeOnlyHarnessSettingChecks = lib.listToAttrs (map (key: {
      name = "module-kimchi-devenv-rejects-user-scope-${key}";
      value = let
        rejected = evalDevenv {
          ai.kimchi = {
            enable = true;
            native.harnessSettings = lib.setAttrByPath [key] (userScopeOnlyHarnessSettingValues.${key}
              or (throw "packages/kimchi/checks/module-eval.nix: add a sample value for the user-scope harness key ${key}"));
          };
        };
        failed = builtins.filter (entry: !entry.assertion) rejected.config.assertions;
        failureMessage =
          if builtins.length failed == 1
          then (builtins.head failed).message
          else null;
        rejectedAttempt = builtins.tryEval (builtins.deepSeq (checkModuleAssertions rejected) true);
        hmAcceptedAttempt = builtins.tryEval (builtins.deepSeq
          (evalHm {
            ai.kimchi = {
              enable = true;
              native.harnessSettings = lib.setAttrByPath [key] userScopeOnlyHarnessSettingValues.${key};
            };
          }).config.home.activation.kimchiHarnessSettingsMerge
          true);
        acceptedAttempt = builtins.tryEval (builtins.deepSeq (checkModuleAssertions (evalDevenv {
            ai.kimchi = {
              enable = true;
              native.harnessSettings.hideThinkingBlock = true;
            };
          }))
          true);
        assertion =
          !rejectedAttempt.success
          && hmAcceptedAttempt.success
          && acceptedAttempt.success
          && failureMessage != null
          && lib.hasInfix key failureMessage
          && lib.hasInfix "either set with HM, or configure inside the harness so it writes to user global" failureMessage;
      in
        (mkTest "kimchi-devenv-rejects-user-scope-${key}" assertion).overrideAttrs (_: {
          passthru.proof = {
            devenvAcceptedAfterRemoval = acceptedAttempt.success;
            devenvRejected = !rejectedAttempt.success;
            homeManagerAccepted = hmAcceptedAttempt.success;
            message = failureMessage;
          };
        });
    })
    userScopeOnlyHarnessSettingKeys);
in {
  imports = [{checks = userScopeOnlyHarnessSettingChecks;}];

  checks = {
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
        && (deliveredFiles devenv.config)."AGENTS.md".text == expected
    );
    # ── Kimchi (mkRuntime factory participant) ──────────────────────────
    module-kimchi-default-disabled = mkTest "kimchi-default-disabled" (!(evalHm {}).config.ai.kimchi.enable);

    module-kimchi-enable-toggles = mkTest "kimchi-enable-toggles" (evalHm {ai.kimchi.enable = true;}).config.ai.kimchi.enable;

    # Regression lock for the flattenDotKeys bug: config.json must be NESTED
    # JSON, never Kiro-style flat dot keys ("redaction.enabled").
    module-kimchi-config-json-nested = mkTest "kimchi-config-json-nested" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            native.settings.redaction.enabled = false;
          };
        };
        text = builtins.toJSON (projectConfigDocument result).value;
      in
        lib.hasInfix ''"redaction":{"enabled":false}'' text
        && !lib.hasInfix "redaction.enabled" text
    );

    # Parity: the same config.json surface triggers the HM activation merge.
    module-kimchi-config-json-hm-merge = mkTest "kimchi-config-json-hm-merge" (
      let
        result = evalHm {
          ai.kimchi = {
            enable = true;
            native.settings.telemetry.enabled = false;
          };
        };
      in
        result.config.home.activation ? kimchiConfigMerge
    );

    # Both documents get their own writer, their own ledger and their own
    # activation entry, and declaring nothing still reaches the reconciler so
    # the prior generation's leaves are retracted. The document a writer owns
    # comes from `_reconciledDocuments`: the reconciler carries the path and
    # the value as data in a store plan, so the activation body names only the
    # plan. The ledger prefixes are the live migration contract every
    # previously written ownership record hangs off.
    #
    # The values ARE empty: every typed sub-option defaults to null or {},
    # and `filterNulls` recurses, so an undeclared Kimchi owns no leaf.
    module-kimchi-hm-empty-settings-emits-writers = mkTest "kimchi-hm-empty-settings-emits-writers" (
      let
        evaluated = evalHm {ai.kimchi.enable = true;};
        activation = evaluated.config.home.activation;
      in
        lib.hasInfix "--phase all" activation.kimchiConfigMerge.text
        && lib.hasInfix "--phase all" activation.kimchiHarnessSettingsMerge.text
        && lib.hasPrefix "json-settings/kimchi-config-" (hmConfigDocument evaluated).ledger
        && lib.hasPrefix "json-settings/kimchi-harness-settings-" (hmHarnessDocument evaluated).ledger
        && (hmConfigDocument evaluated).value == {}
        && (hmHarnessDocument evaluated).value == {}
    );

    # Upgrade contract: generations before project-path delivery keyed both HM
    # ledgers by configDir. Changing either identity strands removed leaves in
    # the user files because the reconciler sees only the newly named ledger.
    module-kimchi-hm-ledger-identity = mkTest "kimchi-hm-ledger-identity" (
      let
        configDir = "custom/kimchi";
        evaluated = evalHm {
          ai.kimchi = {
            inherit configDir;
            enable = true;
          };
        };
        suffix = builtins.hashString "sha256" configDir;
      in
        (hmConfigDocument evaluated).ledger
        == "json-settings/kimchi-config-${suffix}.json"
        && (hmHarnessDocument evaluated).ledger
        == "json-settings/kimchi-harness-settings-${suffix}.json"
    );

    # native.harnessSettings render to harness/settings.json (mutable-state tree).
    module-kimchi-harness-settings = mkTest "kimchi-harness-settings" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            native.harnessSettings.hideThinkingBlock = true;
          };
        };
      in
        result.config.tasks ? "ai:kimchi:harness-settings-merge"
        && (projectHarnessDocument result).value.hideThinkingBlock
        && !(result.config.files ? ".config/kimchi/harness/settings.json")
    );

    # Kimchi persists the normalized values unchanged at pi's
    # `defaultThinkingLevel`. Cover both writers and prove a consumer-authored
    # native value wins over the derived mkDefault.
    module-kimchi-normalized-reasoning-effort = mkTest "kimchi-normalized-reasoning-effort" (
      let
        config.ai = {
          kimchi.enable = true;
          settings.reasoningEffort = "high";
        };
        overridden = evalDevenv {
          ai = {
            kimchi = {
              enable = true;
              native.harnessSettings.defaultThinkingLevel = "low";
            };
            settings.reasoningEffort = "high";
          };
        };
      in
        (hmHarnessDocument (evalHm config)).value.defaultThinkingLevel
        or null
        == "high"
        && (projectHarnessDocument (evalDevenv config)).value.defaultThinkingLevel or null == "high"
        && (projectHarnessDocument overridden).value.defaultThinkingLevel or null == "low"
    );

    # Kimchi 1.1.30 renames a temporary over the user harness/mcp.json
    # (first-run migration, ACP import) and the project .kimchi/mcp.json
    # (`/mcp enable|disable`), which silently replaces a store symlink. So HM
    # must reconcile it by leaf rather than link it, and an empty declaration
    # must still reach the writer so removing the last server retracts it.
    module-kimchi-hm-mcp-reconciled = mkTest "kimchi-hm-mcp-reconciled" (
      let
        evaluated = evalHm {
          ai = {
            kimchi.enable = true;
            mcpServers.example = {
              package = pkgs.hello;
              command = "hello";
              type = "stdio";
            };
          };
        };
        empty = evalHm {ai.kimchi.enable = true;};
        suffix = builtins.hashString "sha256" ".config/kimchi";
      in
        evaluated.config.home.activation ? kimchiMcpMerge
        && (hmMcpDocument evaluated).value.mcpServers.example.command == "hello"
        && (hmMcpDocument evaluated).ledger == "json-settings/kimchi-mcp-${suffix}.json"
        && !(evaluated.config.home.file ? ".config/kimchi/harness/mcp.json")
        && empty.config.home.activation ? kimchiMcpMerge
        && (hmMcpDocument empty).value == {}
    );

    # Kimchi 1.1.30 accepts a role value only as a provider/model string, or
    # for delegable roles a non-empty list of them
    # (src/extensions/orchestration/model-roles.ts:117-181). Anything else is
    # discarded with a warning at runtime, so the option type rejects it. The
    # role names, and which roles take one string, come from extracted.json.
    module-kimchi-model-roles-shape = mkTest "kimchi-model-roles-shape" (
      let
        withRoles = modelRoles:
          evalHm {
            ai.kimchi = {
              enable = true;
              native.harnessSettings.modelRoles = modelRoles;
            };
          };
        valid = evaluated: lib.all (entry: entry.assertion) evaluated.config.assertions;
        rolesTypeCheck = modelRoles:
          (builtins.tryEval (builtins.deepSeq
            (withRoles modelRoles).config.ai.kimchi.native.harnessSettings
            true)).success;
        typeChecks = value: rolesTypeCheck {builder = value;};
        rendered = withRoles {
          builder = ["a/b" "c/d"];
          orchestrator = "a/b";
        };
      in
        valid rendered
        && (hmHarnessDocument rendered).value.modelRoles
        == {
          builder = ["a/b" "c/d"];
          orchestrator = "a/b";
        }
        && typeChecks "provider/model"
        && !(typeChecks "")
        && !(typeChecks "  ")
        && !(typeChecks [])
        && !(typeChecks [""])
        && !(typeChecks {provider = "a";})
        && !(rolesTypeCheck {unknown = "a/b";})
        && !(rolesTypeCheck {orchestrator = ["a/b"];})
        && !(rolesTypeCheck {compactor = ["a/b"];})
        && rolesTypeCheck {compactor = "a/b";}
    );

    # Kimchi 1.1.30 reads `projectExtras.skillPaths ?? globalExtras.skillPaths`
    # (src/config.ts:526): a project `[]` replaces the user's global list, so
    # an undeclared skillPaths must leave the key out of .kimchi/config.json.
    # An explicit list, empty included, still lands.
    module-kimchi-skill-paths-inherit = mkTest "kimchi-skill-paths-inherit" (
      let
        withPaths = extra:
          projectConfigDocument (evalDevenv {
            ai.kimchi =
              {
                enable = true;
              }
              // extra;
          });
      in
        !((withPaths {}).value ? skillPaths)
        && (withPaths {native.settings.skillPaths = [];}).value.skillPaths == []
        && (withPaths {native.settings.skillPaths = [".custom/skills"];}).value.skillPaths == [".custom/skills"]
    );

    module-kimchi-devenv-project-paths = mkTest "kimchi-devenv-project-paths" (
      let
        result = evalDevenv {
          ai = {
            context.text = "Project context.";
            kimchi = {
              configDir = "custom/kimchi";
              context.filename = "custom.md";
              enable = true;
              native.settings.redaction.enabled = false;
            };
            mcpServers.example = {
              package = pkgs.hello;
              command = "hello";
              type = "stdio";
            };
            skills.example = ../../claude-code/checks/fixtures/claude-skills/skill-a;
          };
        };
        files = deliveredFiles result.config;
      in
        (projectConfigDocument result).value.redaction.enabled
        == false
        && result.config.tasks ? "ai:kimchi:mcp-merge"
        && (projectMcpDocument result).value.mcpServers.example.command == "hello"
        && !(files ? ".kimchi/mcp.json")
        && files ? ".kimchi/skills/example/SKILL.md"
        && files ? "AGENTS.md"
        && !(files ? "custom.md")
        && !(lib.any (lib.hasPrefix "custom/kimchi") (builtins.attrNames files))
    );

    # Kimchi 1.1.30 reads lifecycle hooks from a trusted project's
    # .kimchi/hooks.json, in the Claude hook shape with timeouts in seconds
    # (src/extensions/kimchi-hooks/definition.ts:25-37,
    # src/extensions/hook-adapters/discovery.ts:130-190), and never writes it.
    # Its event set has no PermissionRequest, so that event is left out of the
    # file rather than written as bytes nothing reads. Home Manager has no
    # user-scope lifecycle file it can own: it writes nothing. Only the
    # per-runtime ai.kimchi.hooks warns there; the shared pool composes with it,
    # so nothing Kimchi-scoped could silence a root warning, and both root
    # exclusions stay silent. Each silence sits beside a warning from the same
    # evaluation, so an evaluation that stopped producing warnings fails.
    module-kimchi-hooks = mkTest "kimchi-hooks" (
      let
        config.ai = {
          hooks = {
            PermissionRequest = [{hooks = [{command = "never";}];}];
            PreToolUse = [
              {
                matcher = "Bash";
                hooks = [
                  {
                    command = "true";
                    timeout = 5;
                  }
                ];
              }
            ];
          };
          kimchi = {
            enable = true;
            hooks.TurnStart = [{hooks = [{command = "turn";}];}];
          };
        };
        devenv = evalDevenv config;
        hm = evalHm config;
        onlyPermissionRequest = evalDevenv {
          ai = {
            hooks.PermissionRequest = [{hooks = [{command = "never";}];}];
            kimchi.enable = true;
          };
        };
        hmRootOnly = evalHm {
          ai = {
            inherit (config.ai) hooks;
            kimchi.enable = true;
          };
        };
        mentions = needle: lib.any (lib.hasInfix needle);
        hmHookPaths = lib.filter (lib.hasInfix "hooks") (builtins.attrNames hm.config.home.file);
      in
        builtins.fromJSON devenv.config.files.".kimchi/hooks.json".text
        == {
          hooks = {
            PreToolUse = [
              {
                matcher = "Bash";
                hooks = [
                  {
                    command = "true";
                    timeout = 5;
                    type = "command";
                  }
                ];
              }
            ];
            TurnStart = [
              {
                hooks = [
                  {
                    command = "turn";
                    type = "command";
                  }
                ];
              }
            ];
          };
        }
        && !mentions "ai.hooks" devenv.config.warnings
        && !(onlyPermissionRequest.config.files ? ".kimchi/hooks.json")
        && onlyPermissionRequest.config.warnings == []
        && !((evalDevenv {ai.kimchi.enable = true;}).config.files ? ".kimchi/hooks.json")
        && hmHookPaths == []
        && !mentions "ai.hooks is set" hm.config.warnings
        && mentions "ai.kimchi.hooks is set but hm does not deliver it to kimchi" hm.config.warnings
        && mentions "claude-code-hook-adapter" hm.config.warnings
        && hmRootOnly.config.warnings == []
        && (evalHm {ai.kimchi.enable = true;}).config.warnings == []
    );

    # Kimchi 1.1.30 reads a hard-coded user permissions.json and a trusted
    # project's .kimchi/permissions.json, validates both with a `.strict()`
    # schema, and rewrites whichever one `/permissions … save` targets
    # (src/extensions/permissions/config.ts:11-37,153; commands.ts:234-237).
    # So both backends reconcile the declared keys by leaf, the HM path
    # ignores configDir, an empty declaration still reaches the writer, and
    # the option refuses any key or value the schema would reject.
    module-kimchi-permissions = mkTest "kimchi-permissions" (
      let
        permissions = {
          allow = ["bash(git status)"];
          defaultMode = "plan";
        };
        hm = evalHm {
          ai.kimchi = {
            inherit permissions;
            configDir = "custom/kimchi";
            enable = true;
          };
        };
        devenv = evalDevenv {
          ai.kimchi = {
            inherit permissions;
            enable = true;
          };
        };
        hmDocument = kimchiDocument ".config/kimchi/harness/permissions.json";
        projectDocument = kimchiDocument ".kimchi/permissions.json";
        emptyHm = evalHm {ai.kimchi.enable = true;};
        emptyDevenv = evalDevenv {ai.kimchi.enable = true;};
        accepts = value:
          (builtins.tryEval (builtins.deepSeq
            (evalHm {
              ai.kimchi = {
                enable = true;
                permissions = value;
              };
            }).config.ai.kimchi.permissions
            true)).success;
      in
        (hmDocument hm).value
        == permissions
        && lib.hasPrefix "json-settings/kimchi-permissions-" (hmDocument hm).ledger
        && hm.config.home.activation ? kimchiPermissionsMerge
        && !(hm.config.home.file ? ".config/kimchi/harness/permissions.json")
        && (projectDocument devenv).value == permissions
        && devenv.config.tasks ? "ai:kimchi:permissions-merge"
        && !(devenv.config.files ? ".kimchi/permissions.json")
        && (hmDocument emptyHm).value == {}
        && emptyHm.config.home.activation ? kimchiPermissionsMerge
        && (projectDocument emptyDevenv).value == {}
        && emptyDevenv.config.tasks ? "ai:kimchi:permissions-merge"
        && accepts {
          classifierMaxTotalMs = 1;
          classifierTimeoutMs = 1;
          deny = [];
        }
        && !(accepts {extra = true;})
        && !(accepts {defaultMode = "ask";})
        && !(accepts {classifierTimeoutMs = 0;})
    );

    # ai.kimchi.projectTrust mirrors trust.json, which ACP consults because it
    # ignores `--approve`. Home Manager owns the declared leaves through its
    # own writer, which follows configDir like harness settings; devenv
    # rejects the option by name rather than dropping it, and each arm has a
    # control that isolates the one input under test.
    module-kimchi-project-trust = mkTest "kimchi-project-trust" (
      let
        projectTrust = {"/srv/projects" = true;};
        hm = evalHm {
          ai.kimchi = {
            inherit projectTrust;
            configDir = "custom/kimchi";
            enable = true;
          };
        };
        target = lib.head (ownPlan "kimchi" "kimchiProjectTrustMerge" hm).targets;
        devenvWith = trust:
          evalDevenv {
            ai.kimchi = {
              enable = true;
              projectTrust = trust;
            };
          };
        rejected = devenvWith projectTrust;
        accepted = devenvWith {};
        hmFailures = trust:
          failedAssertions (evalHm {
            ai.kimchi = {
              enable = true;
              projectTrust = trust;
            };
          });
      in
        target.path
        == "custom/kimchi/harness/trust.json"
        && target.codec == "json"
        && lib.hasPrefix "json-settings/kimchi-project-trust-" target.ledger
        && lib.hasInfix "project-trust.py" target.units.run
        && !(hm.config.home.file ? "custom/kimchi/harness/trust.json")
        && hmFailures projectTrust == []
        && builtins.any (lib.hasInfix "must be absolute paths") (hmFailures {"srv/projects" = true;})
        && builtins.any (lib.hasInfix "ai.kimchi.projectTrust is user scope") (failedAssertions rejected)
        && failedAssertions accepted == []
        # Devenv declares no trust writer of any kind, even when accepted.
        && !(lib.any (target: lib.hasSuffix "trust.json" target.path)
          (lib.concatMap (record: record.plan.targets) (lib.attrValues accepted.config.ai.kimchi._ownPlans)))
        && !(lib.any (lib.hasSuffix "trust.json") (builtins.attrNames accepted.config.files))
    );

    # Runs the real Home Manager writer. A key reached through a symlink must
    # land under its realpath, the only key pi 0.85.1 ever looks up
    # (findNearestTrustEntry); a missing tail is still declared; a decision
    # Kimchi's prompt wrote survives; an empty declaration retracts only what
    # was owned; and two keys resolving to one directory with different
    # answers fail the writer without touching the file.
    module-kimchi-project-trust-runtime = let
      fixture = pkgs.runCommand "kimchi-project-trust-fixture" {} ''
        mkdir -p "$out/real/project"
        ln -s real "$out/link"
      '';
      # An attribute name cannot carry string context. The runCommand below
      # interpolates `fixture` itself, which keeps it in the check's closure.
      under = relative: builtins.unsafeDiscardStringContext "${fixture}/${relative}";
      writer = projectTrust:
        pkgs.writeShellScript "kimchi-project-trust" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          # This is an HM activation entry, which expects home-manager's `run`
          # helper (lib/bash/home-manager.sh) already in scope.
          ${harness.hmRunShim}
          ${(evalHm {
            ai.kimchi = {
              enable = true;
              inherit projectTrust;
            };
          }).config.home.activation.kimchiProjectTrustMerge.text}
        '';
      declared = writer {
        ${under "link/project"} = true;
        "/nonexistent/kimchi-project" = false;
      };
      conflicting = writer {
        ${under "link/project"} = true;
        ${under "real/project"} = false;
      };
      empty = writer {};
    in
      pkgs.runCommand "module-test-kimchi-project-trust-runtime" {nativeBuildInputs = [pkgs.jq];} ''
        fail() { echo "FAIL: kimchi-project-trust-runtime: $1" >&2; exit 1; }
        export HOME="$TMPDIR/home"
        export XDG_STATE_HOME="$TMPDIR/state"
        trust="$HOME/.config/kimchi/harness/trust.json"
        mkdir -p "$(dirname "$trust")"
        # A decision Kimchi's own prompt persisted before activation.
        printf '{\n  "/prompted": true\n}\n' > "$trust"

        ${declared}
        jq -e --arg real '${fixture}/real/project' '.[$real] == true' "$trust" >/dev/null \
          || fail "the symlinked key did not land under its realpath: $(cat "$trust")"
        jq -e --arg link '${fixture}/link/project' 'has($link) | not' "$trust" >/dev/null \
          || fail "the literal symlinked key was written, which Kimchi never matches"
        jq -e '.["/nonexistent/kimchi-project"] == false' "$trust" >/dev/null \
          || fail 'a declared path that does not exist yet was dropped'
        jq -e '.["/prompted"] == true' "$trust" >/dev/null \
          || fail 'a prompted decision was lost'

        cp "$trust" "$TMPDIR/before-conflict"
        if ${conflicting} 2>"$TMPDIR/conflict.err"; then
          fail 'two keys resolving to one directory with different decisions were accepted'
        fi
        grep -q 'declare different decisions' "$TMPDIR/conflict.err" \
          || fail "the conflict did not name its cause: $(cat "$TMPDIR/conflict.err")"
        cmp "$TMPDIR/before-conflict" "$trust" || fail 'a failed render changed trust.json'

        ${empty}
        jq -e '. == {"/prompted": true}' "$trust" >/dev/null \
          || fail "an empty declaration did not retract exactly the owned leaves: $(cat "$trust")"

        # pi's trust prompt, mid read-modify-write: it holds proper-lockfile's
        # `trust.json.lock` directory, has read the file, and writes it back
        # with its new decision. The writer must wait for that lock and then
        # build on pi's bytes; an unlocked writer lands first and pi's stale
        # rewrite drops every declared leaf.
        mkdir "$trust.lock"
        snapshot="$(cat "$trust")"
        ${declared} &
        writer=$!
        sleep 1
        jq -e 'has("/nonexistent/kimchi-project") | not' "$trust" >/dev/null \
          || fail "the writer did not wait for pi's trust.json lock"
        jq '. + {"/during": true}' <<<"$snapshot" > "$trust"
        rmdir "$trust.lock"
        wait "$writer" || fail 'the writer failed after pi released its lock'
        jq -e '.["/during"] == true and .["/nonexistent/kimchi-project"] == false' "$trust" >/dev/null \
          || fail "a decision saved under pi's lock or a declared leaf was lost: $(cat "$trust")"
        [ ! -e "$trust.lock" ] || fail 'the writer left the lock behind'

        # A lock whose holder died goes stale after proper-lockfile's 10 s, and
        # pi breaks it then; so does the writer, instead of failing activation.
        ${empty}
        mkdir "$trust.lock"
        touch -d "@$(( $(date +%s) - 60 ))" "$trust.lock"
        ${declared} || fail 'a stale pi lock blocked the writer'
        [ ! -e "$trust.lock" ] || fail 'the stale lock survived the writer'
        jq -e '.["/nonexistent/kimchi-project"] == false' "$trust" >/dev/null \
          || fail "the writer did not land past a stale lock: $(cat "$trust")"
        echo PASS > "$out"
      '';

    # Kimchi reads `<agentDir>/agents/*.md` and a trusted project's
    # `.kimchi/agents/*.md`, and its /agents commands write both in place
    # (src/extensions/agents/index.ts:2556-2874). So each agent is an OWNED,
    # WRITABLE real file in a real directory, never a store symlink: no
    # home.file or devenv files entry, a dir ledger, mode 0644. A portable
    # record renders without `name:` (the filename is the name); native
    # Markdown lands verbatim. An empty declaration still emits the writer, so
    # removing the last agent retracts it.
    module-kimchi-agents = mkTest "kimchi-agents" (
      let
        hm = evalHm agentConfig;
        devenv = evalDevenv agentConfig;
        expected = {
          "native.md" = {
            mode = "0644";
            text = nativeAgent;
          };
          "reviewer.md" = {
            mode = "0644";
            text = "---\ndescription: \"Reviews code\"\n---\n\nBODY\n";
          };
        };
        emptyHm = evalHm {ai.kimchi.enable = true;};
        emptyDevenv = evalDevenv {ai.kimchi.enable = true;};
        fromDir = evalDevenv {
          ai.kimchi = {
            enable = true;
            agentsDir = ../../claude-code/checks/fixtures/claude-agents;
          };
        };
        # A store-path STRING, as a flake input yields, both as one agent and
        # as the directory: delivered as a source, never as text holding the
        # path, the way Home Manager's `isPathLike` decides.
        fixtureAgent = "${../../claude-code/checks/fixtures/claude-agents}/agent-one.md";
        stringConfig.ai.kimchi = {
          enable = true;
          agents.store-string = fixtureAgent;
          agentsDir = {
            path = "${../../claude-code/checks/fixtures/claude-agents}";
            filter = name: name == "agent-one.md";
          };
        };
        deliveredAsSource = units:
          lib.all (unit: toString (unit.store or "") == fixtureAgent && !(unit ? text))
          [units."agent-one.md" units."store-string.md"];
        underAgents = prefix: lib.filter (lib.hasPrefix prefix);
      in
        hmAgentUnits hm
        == expected
        && devenvAgentUnits devenv == expected
        && failedAssertions hm == []
        && failedAssertions devenv == []
        && hm.config.home.activation ? kimchiAgents
        && hm.config.home.activation ? kimchiAgentsPrune
        && devenv.config.tasks ? "ai:kimchi:agents"
        && underAgents ".config/kimchi/harness/agents" (builtins.attrNames hm.config.home.file) == []
        && underAgents ".kimchi/agents" (builtins.attrNames devenv.config.files) == []
        && hmAgentUnits emptyHm == {}
        && devenvAgentUnits emptyDevenv == {}
        && (devenvAgentUnits fromDir)."agent-one.md".store == ../../claude-code/checks/fixtures/claude-agents/agent-one.md
        && deliveredAsSource (hmAgentUnits (evalHm stringConfig))
        && deliveredAsSource (devenvAgentUnits (evalDevenv stringConfig))
    );

    # What has no Kimchi reading fails evaluation instead of landing: a
    # record's Claude/Copilot `tools` list, and root Markdown written for
    # Claude/Copilot. A null or a Kimchi-native value under ai.kimchi.agents is
    # the remedy each message names, and it clears the failure.
    module-kimchi-agents-rejected = mkTest "kimchi-agents-rejected" (
      let
        failures = evaluate: agents: kimchiAgents:
          failedAssertions (evaluate {
            ai = {
              inherit agents;
              kimchi = {
                enable = true;
                agents = kimchiAgents;
              };
            };
          });
        withTools = {
          description = "d";
          instructions.text = "BODY";
          tools = ["Read"];
        };
        claudeMarkdown = "---\nname: probe\nmodel: sonnet\n---\n\nBODY\n";
        dirFailures = evaluate: kimchiAgents:
          failedAssertions (evaluate {
            ai = {
              agentsDir = ../../claude-code/checks/fixtures/claude-agents;
              kimchi = {
                enable = true;
                agents = kimchiAgents;
              };
            };
          });
        says = needle: lib.any (lib.hasInfix needle);
      in
        lib.all (evaluate:
          says "carry a `tools` allowlist" (failures evaluate {probe = withTools;} {})
          && says "carry a `tools` allowlist" (failures evaluate {} {probe = withTools;})
          && says "Markdown written for Claude/Copilot" (failures evaluate {probe = claudeMarkdown;} {})
          && failures evaluate {probe = claudeMarkdown;} {probe = null;} == []
          && failures evaluate {probe = claudeMarkdown;} {probe = nativeAgent;} == []
          && failures evaluate {probe = withTools // {tools = [];};} {} == []
          # Root agentsDir feeds ai.agents, so a Claude agents directory is
          # rejected too — not skipped silently, as the option once said — and
          # withdrawing each name is the per-runtime remedy.
          && says "Markdown written for Claude/Copilot" (dirFailures evaluate {})
          && dirFailures evaluate {
            agent-one = null;
            agent-two = null;
          }
          == [])
        [evalHm evalDevenv]
    );

    # The delivery itself, executed: the real HM prune and write entries and
    # the real devenv task, against scratch roots. A Kimchi edit (Edit and
    # Disable overwrite the file in place) must SUCCEED, the next run must back
    # it up and restore the declaration, a file Kimchi created beside it must
    # survive, and an empty declaration must remove only the owned file.
    module-kimchi-agents-runtime = let
      script = backend: evaluated:
        pkgs.writeShellScript "kimchi-agents-${backend}" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${
            # The hm branch is HM activation entry text and needs
            # home-manager's `run` helper in scope; the devenv task's `.exec`
            # defines no such helper and must not get one.
            if backend == "hm"
            then harness.hmRunShim + evaluated.config.home.activation.kimchiAgentsPrune.text + "\n" + evaluated.config.home.activation.kimchiAgents.text
            else evaluated.config.tasks."ai:kimchi:agents".exec
          }
        '';
      run = backend: let
        evaluate =
          if backend == "hm"
          then evalHm
          else evalDevenv;
        dir =
          if backend == "hm"
          then ".config/kimchi/harness/agents"
          else ".kimchi/agents";
        declared = script backend (evaluate agentConfig);
        empty = script backend (evaluate {ai.kimchi.enable = true;});
        expected = pkgs.writeText "kimchi-reviewer.md" (hmAgentUnits (evalHm agentConfig))."reviewer.md".text;
      in ''
        export HOME="$TMPDIR/${backend}-home"
        export XDG_STATE_HOME="$TMPDIR/${backend}-state"
        export DEVENV_ROOT="$HOME"
        export DEVENV_STATE="$XDG_STATE_HOME"
        mkdir -p "$HOME"
        agent="$HOME/${dir}/reviewer.md"

        ${declared}
        [ -f "$agent" ] && [ ! -L "$agent" ] || fail '${backend}: agent is not a real file'
        [ ! -L "$HOME/${dir}" ] || fail '${backend}: agents directory is a symlink'
        [ "$(stat -c %a "$agent")" = 644 ] || fail '${backend}: agent is not writable'
        cmp ${expected} "$agent" || fail '${backend}: agent content'

        # Kimchi's /agents Disable and Edit, and a Create beside it.
        printf -- '---\nenabled: false\n' > "$agent" || fail '${backend}: an in-place edit was refused'
        printf 'created\n' > "$HOME/${dir}/created.md"

        ${declared}
        cmp ${expected} "$agent" || fail '${backend}: the declaration was not restored'
        ls "$XDG_STATE_HOME"/nix-agentic-tools/materialize/kimchi-agents-*.bak/reviewer.md.* >/dev/null \
          || fail '${backend}: the edit was not backed up'
        [ "$(cat "$HOME/${dir}/created.md")" = created ] || fail '${backend}: a Kimchi-created agent changed'

        ${empty}
        [ ! -e "$agent" ] || fail '${backend}: an empty declaration kept the agent'
        [ "$(cat "$HOME/${dir}/created.md")" = created ] || fail '${backend}: retraction touched an unowned agent'
      '';
    in
      pkgs.runCommand "module-test-kimchi-agents-runtime" {} ''
        fail() { echo "FAIL: kimchi-agents-runtime: $1" >&2; exit 1; }
        ${run "hm"}
        ${run "devenv"}
        echo PASS > "$out"
      '';

    module-kimchi-devenv-exact-cwd-guard = let
      guardedPackages = [
        (mkDevenvKimchiPackage {
          ai.kimchi.native.settings.redaction.enabled = false;
        })
        (mkDevenvKimchiPackage {
          ai.kimchi.native.harnessSettings.hideThinkingBlock = true;
        })
        (mkDevenvKimchiPackage {
          ai.mcpServers.example = {
            package = pkgs.hello;
            type = "stdio";
          };
        })
        (mkDevenvKimchiPackage {
          ai.hooks.PreToolUse = [{hooks = [{command = "true";}];}];
        })
        (mkDevenvKimchiPackage {
          ai.kimchi.agents.native = nativeAgent;
        })
        (mkDevenvKimchiPackage {
          ai.kimchi.permissions.defaultMode = "plan";
        })
      ];
      # Nothing exact-cwd is declared, so nothing is missed from a
      # subdirectory and the wrapper must not refuse the launch.
      unguardedPackage = mkDevenvKimchiPackage {};
    in
      pkgs.runCommand "module-test-kimchi-devenv-exact-cwd-guard" {} ''
        (cd ${exactCwdProjectRoot}/subdir && ${unguardedPackage}/bin/kimchi)

        for kimchi_bin in ${lib.concatMapStringsSep " " (package: "${package}/bin/kimchi") guardedPackages}; do
          (cd ${exactCwdProjectRoot} && "$kimchi_bin")
          if (cd ${exactCwdProjectRoot}/subdir && "$kimchi_bin" 2>"$TMPDIR/guard.stderr"); then
            echo "Kimchi exact-cwd guard did not reject a descendant launch" >&2
            exit 1
          fi
          grep -F "Kimchi project files are configured at ${exactCwdProjectRoot}; run kimchi from that devenv root." "$TMPDIR/guard.stderr"
        done

        echo PASS > "$out"
      '';

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
