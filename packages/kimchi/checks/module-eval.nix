# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest ownedDocument;
  kimchiDocument = leaf: evaluated:
    ownedDocument "kimchi" "${evaluated.config.ai.kimchi.configDir}/${leaf}" evaluated;
  configDocument = kimchiDocument "config.json";
  harnessDocument = kimchiDocument "harness/settings.json";
in {
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
        && devenv.config.files.".config/kimchi/harness/AGENTS.md".text == expected
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
        text = result.config.files.".config/kimchi/config.json".text;
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
        && lib.hasPrefix "json-settings/kimchi-config-" (configDocument evaluated).ledger
        && lib.hasPrefix "json-settings/kimchi-harness-settings-" (harnessDocument evaluated).ledger
    );

    # harnessSettings render to harness/settings.json (mutable-state tree).
    module-kimchi-harness-settings = mkTest "kimchi-harness-settings" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            harnessSettings.resources."tools.web_search" = true;
          };
        };
      in
        result.config.files ? ".config/kimchi/harness/settings.json"
    );

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
