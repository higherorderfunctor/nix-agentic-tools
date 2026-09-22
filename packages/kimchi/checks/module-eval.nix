# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
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

  # lib.evalModules exposes assertions as data; the real HM/devenv callers
  # reject failed entries. Reproduce that boundary so every negative control
  # must actually throw, while the matching project-safe control must pass.
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
        text = result.config.files.".kimchi/config.json".text;
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

    # Project files must use the exact paths Kimchi discovers. A custom
    # user-global configDir must not redirect devenv back into a HOME-shaped
    # project subtree.
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
              type = "stdio";
            };
            skills.example = ../../claude-code/checks/fixtures/claude-skills/skill-a;
          };
        };
        files = result.config.files;
      in
        files ? ".kimchi/config.json"
        && files ? ".kimchi/mcp.json"
        && files ? ".kimchi/skills/example/SKILL.md"
        && files ? "AGENTS.md"
        && !(files ? "custom.md")
        && !(lib.any (lib.hasPrefix "custom/kimchi") (builtins.attrNames files))
    );

    # pi's CONFIG_DIR_NAME comes from Kimchi's package metadata, so project
    # harness settings use its fixed path rather than .pi or the user configDir.
    module-kimchi-harness-settings-devenv-project-path = mkTest "kimchi-harness-settings-devenv-project-path" (
      let
        result = evalDevenv {
          ai.kimchi = {
            configDir = "custom/kimchi";
            enable = true;
            harnessSettings.hideThinkingBlock = true;
          };
        };
        files = result.config.files;
        text = files.".config/kimchi/harness/settings.json".text;
      in
        lib.hasInfix ''"hideThinkingBlock":true'' text
        && !(files ? ".pi/settings.json")
        && !(lib.any (lib.hasPrefix "custom/kimchi") (builtins.attrNames files))
    );

    # Kimchi resolves these three project files from process.cwd() exactly,
    # unlike context and skills, which walk ancestors. Exercise every
    # exact-cwd configuration shape against a real wrapped binary. The typed
    # native settings include default skillPaths, so every enabled devenv
    # Kimchi currently owns project config and must reject descendant launches.
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
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

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
