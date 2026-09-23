# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest ownedDocument;
  kimchiDocument = path: ownedDocument "kimchi" path;
  hmConfigDocument = evaluated: kimchiDocument "${evaluated.config.ai.kimchi.configDir}/config.json" evaluated;
  hmHarnessDocument = evaluated: kimchiDocument "${evaluated.config.ai.kimchi.configDir}/harness/settings.json" evaluated;
  projectConfigDocument = kimchiDocument ".kimchi/config.json";
  projectHarnessDocument = kimchiDocument ".config/kimchi/harness/settings.json";
  projectMcpDocument = kimchiDocument ".kimchi/mcp.json";
  hmMcpDocument = evaluated: kimchiDocument "${evaluated.config.ai.kimchi.configDir}/harness/mcp.json" evaluated;
  userScopeOnlyHarnessSettingKeys = import ../lib/user-scope-only-harness-settings.nix;
  userScopeOnlyHarnessSettingValues = {
    defaultProjectTrust = "always";
    fermentV2 = true;
    hidePhaseChanges = true;
    modelMetadata.example.description = "Example model";
    modelRoles.example.provider = "example";
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
            harnessSettings = lib.setAttrByPath [key] userScopeOnlyHarnessSettingValues.${key};
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
              harnessSettings = lib.setAttrByPath [key] userScopeOnlyHarnessSettingValues.${key};
            };
          }).config.home.activation.kimchiHarnessSettingsMerge
          true);
        acceptedAttempt = builtins.tryEval (builtins.deepSeq (checkModuleAssertions (evalDevenv {
            ai.kimchi = {
              enable = true;
              harnessSettings.hideThinkingBlock = true;
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
        && devenv.config.files."AGENTS.md".text == expected
    );
    # ── Kimchi (mkAiApp factory participant) ──────────────────────────
    module-kimchi-default-disabled = mkTest "kimchi-default-disabled" (!(evalHm {}).config.ai.kimchi.enable);

    module-kimchi-enable-toggles = mkTest "kimchi-enable-toggles" (evalHm {ai.kimchi.enable = true;}).config.ai.kimchi.enable;

    # Regression lock for the flattenDotKeys bug: config.json must be NESTED
    # JSON, never Kiro-style flat dot keys ("telemetry.enabled").
    module-kimchi-config-json-nested = mkTest "kimchi-config-json-nested" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            nativeSettings.telemetry.enabled = false;
          };
        };
        text = builtins.toJSON (projectConfigDocument result).value;
      in
        lib.hasInfix ''"telemetry":{"enabled":false}'' text
        && !lib.hasInfix "telemetry.enabled" text
    );

    # Parity: the same config.json surface triggers the HM activation merge.
    module-kimchi-config-json-hm-merge = mkTest "kimchi-config-json-hm-merge" (
      let
        result = evalHm {
          ai.kimchi = {
            enable = true;
            nativeSettings.telemetry.enabled = false;
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
    # The values are NOT asserted empty here. `nativeSettings` and
    # `harnessSettings` are submodules with defaulted sub-options, so an
    # undeclared Kimchi still owns `telemetry.enabled` and friends; that is
    # pre-existing and `filterNulls` is deliberately shallow.
    module-kimchi-hm-empty-settings-emits-writers = mkTest "kimchi-hm-empty-settings-emits-writers" (
      let
        evaluated = evalHm {ai.kimchi.enable = true;};
        activation = evaluated.config.home.activation;
      in
        lib.hasInfix "--phase all" activation.kimchiConfigMerge.text
        && lib.hasInfix "--phase all" activation.kimchiHarnessSettingsMerge.text
        && lib.hasPrefix "json-settings/kimchi-config-" (hmConfigDocument evaluated).ledger
        && lib.hasPrefix "json-settings/kimchi-harness-settings-" (hmHarnessDocument evaluated).ledger
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

    # harnessSettings render to harness/settings.json (mutable-state tree).
    module-kimchi-harness-settings = mkTest "kimchi-harness-settings" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            harnessSettings.hideThinkingBlock = true;
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
              harnessSettings.defaultThinkingLevel = "low";
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

    module-kimchi-devenv-project-paths = mkTest "kimchi-devenv-project-paths" (
      let
        result = evalDevenv {
          ai = {
            context.text = "Project context.";
            kimchi = {
              configDir = "custom/kimchi";
              context.filename = "custom.md";
              enable = true;
              nativeSettings.telemetry.enabled = false;
            };
            mcpServers.example = {
              package = pkgs.hello;
              command = "hello";
              type = "stdio";
            };
            skills.example = ../../claude-code/checks/fixtures/claude-skills/skill-a;
          };
        };
        files = result.config.files;
      in
        (projectConfigDocument result).value.telemetry.enabled
        == false
        && result.config.tasks ? "ai:kimchi:mcp-merge"
        && (projectMcpDocument result).value.mcpServers.example.command == "hello"
        && !(files ? ".kimchi/mcp.json")
        && files ? ".kimchi/skills/example/SKILL.md"
        && files ? "AGENTS.md"
        && !(files ? "custom.md")
        && !(lib.any (lib.hasPrefix "custom/kimchi") (builtins.attrNames files))
    );

    module-kimchi-devenv-exact-cwd-guard = let
      guardedPackages = [
        (mkDevenvKimchiPackage {
          ai.kimchi.nativeSettings.telemetry.enabled = false;
        })
        (mkDevenvKimchiPackage {
          ai.kimchi.harnessSettings.hideThinkingBlock = true;
        })
        (mkDevenvKimchiPackage {
          ai.mcpServers.example = {
            package = pkgs.hello;
            type = "stdio";
          };
        })
      ];
    in
      pkgs.runCommand "module-test-kimchi-devenv-exact-cwd-guard" {} ''
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
