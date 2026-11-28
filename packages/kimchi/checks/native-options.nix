# `ai.kimchi.native.*` follows packages/kimchi/extracted/ facts.
#
# The option types are generated from the committed aggregate by
# ../lib/extracted.nix. Agreement with the real aggregate alone would also hold
# for a hand-copied option list, so the cases that matter run the same
# generator over FIXTURE values — one key added, one removed, one enum
# widened — and require the option surface to move with it. Each case is named
# in the failure message.
{
  extractedLib,
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows evalDevenv rejectsChange;
  evalHm = config: harness.evalHm (lib.mkMerge [{ai.kimchi.native.settings.region = lib.mkOverride 1200 "us";} config]);
  inherit (extractedLib {inherit pkgs;}) get load;
  inherit (load {dir = ../extracted;}) aggregate;
  committedRows = builtins.fromJSON (builtins.readFile ../extract/annotations.json);
  surfaceFor = {
    changes ? {},
    removed ? [],
    rows ? null,
  }:
    import ../lib/extracted.nix {
      inherit extractedLib lib pkgs rows;
      aggregate = builtins.removeAttrs (lib.recursiveUpdate aggregate (lib.mapAttrs (_: value: {inherit value;}) changes)) removed;
    };
  real = surfaceFor {};
  sorted = lib.sort (a: b: a < b);

  # One harness key added, one config key removed, one enum value added.
  fixture = surfaceFor {
    changes = {
      "harness.keys.doubleEscapeAction".enum = (get aggregate "harness.keys.doubleEscapeAction").enum ++ ["probe"];
      "harness.keys.probeAdded" = {
        optional = true;
        type = "boolean";
        typeExpression = "boolean";
      };
    };
    removed = ["config.keys.llmEndpoint"];
  };
  # A hand-table row whose path is gone, and a key whose type nothing maps.
  withoutSkillPaths = surfaceFor {removed = ["config.keys.skillPaths"];};
  withUnion = surfaceFor {
    changes."harness.keys.probeUnion" = {
      optional = true;
      type = "union";
      typeExpression = "string | number";
    };
  };
  withUserScopeTheme = surfaceFor {changes."harness.keys.theme".project = false;};
  withConsumedInertKey = surfaceFor {changes."config.keys.mcpSearchLimit".inert = false;};
  withoutOwnVariable = surfaceFor {changes."environment.variables.KIMCHI_REGION".consumerOverridable = false;};
  # Annotation rows with one harness key and one config key ignored. Both keys
  # have an option on the real surface and nothing in the factory reads them.
  withIgnoredRows = surfaceFor {
    rows = lib.recursiveUpdate committedRows {
      config.llmEndpoint.ignored = "probe";
      harness.httpProxy.ignored = "probe";
    };
  };

  # Read the precise field through the generated, closed submodule's merge.
  mergeNative = options: value:
    (lib.evalModules {
      modules = [
        {
          options.native = lib.mkOption {
            type = lib.types.submodule {inherit options;};
            default = {};
          };
        }
        {config.native = value;}
      ];
    }).config.native;
  harnessOption = name: input: (mergeNative real.harnessSettingsOptions {${name} = input;}).${name};
  failedAssertions = evaluated: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) evaluated.config.assertions);
  # The user harness settings.json Home Manager copies, decoded.
  hmHarnessSettings = evaluated:
    evaluated.config.ai.files."${evaluated.config.ai.kimchi.configDir}/harness/settings.json".content.value;
  hmHarness = harnessSettings:
    hmHarnessSettings (evalHm {
      ai.kimchi = {
        enable = true;
        native = {inherit harnessSettings;};
      };
    });

  portableEfforts = ["high" "low" "medium" "xhigh"];
  declaredEfforts =
    ((evalHm {}).options.ai.settings.type.getSubOptions []).reasoningEffort.type.nestedTypes.elemType.functor.payload.values;
  loweredEffort = effort:
    (hmHarnessSettings (evalHm {
      ai = {
        kimchi.enable = true;
        settings.reasoningEffort = effort;
      };
    }))
    .defaultThinkingLevel
    or null;

  # `telemetry.endpoint`, because devenv passes `telemetry.enabled` through
  # the launcher environment rather than the project file.
  devenvTelemetry = evalDevenv {
    ai.kimchi = {
      enable = true;
      native.settings.telemetry.endpoint = "https://example.invalid";
    };
  };
  hmTelemetry = evalHm {
    ai.kimchi = {
      enable = true;
      native.settings.telemetry.endpoint = "https://example.invalid";
    };
  };
  fixedVariable = extra:
    failedAssertions (evalHm {
      ai = lib.recursiveUpdate {kimchi.enable = true;} extra;
    });

  # Every reconciled entry must appear on exactly one consumer-facing
  # surface: supported options or the documented exclusion report.
  completeSurface = options: excluded: entries:
    builtins.attrNames (options // excluded)
    == builtins.attrNames entries
    && builtins.intersectAttrs options excluded == {};
  completeNative = surface:
    completeSurface surface.settingsOptions surface.report.excluded.settings surface.rules.results.config.entries
    && completeSurface surface.harnessSettingsOptions surface.report.excluded.harnessSettings surface.rules.results.harness.entries;

  cases = {
    added-key-appears = rejectsChange (options: (mergeNative options {probeAdded = true;}).probeAdded) {
      expected = true;
      invalid = real.harnessSettingsOptions;
      valid = fixture.harnessSettingsOptions;
    };

    enum-follows-the-sidecar =
      rejectsChange (harnessOption "doubleEscapeAction") {
        expected = "tree";
        invalid = "probe";
        valid = "tree";
      }
      && (mergeNative fixture.harnessSettingsOptions {doubleEscapeAction = "probe";}).doubleEscapeAction == "probe";

    every-type-is-mapped =
      real.report.untyped
      == []
      && withUnion.report.untyped == ["harnessSettings.probeUnion"];

    # PI_CODING_AGENT_DIR is overwritten too, but entry.ts reads it first and
    # preserves it, so the derived flag must leave it settable.
    fixed-environment-is-rejected =
      lib.any (lib.hasInfix "PI_SKIP_VERSION_CHECK: src/entry.ts assigns it on every launch before anything reads it") (fixedVariable {kimchi.environmentVariables.PI_SKIP_VERSION_CHECK = "0";})
      && fixedVariable {kimchi.environmentVariables.PI_CODING_AGENT_DIR = "/srv/pi-agent";} == []
      && fixedVariable {
        environmentVariables.PI_SKIP_VERSION_CHECK = "0";
        kimchi.environmentVariables.PI_SKIP_VERSION_CHECK = null;
      }
      == []
      && fixedVariable {kimchi.environmentVariables.KIMCHI_EXTRA = "yes";} == [];

    # The helper's boolean is optional but must not accept a string lookalike.
    helper-guard-derived-option =
      rejectsChange (harnessOption "workSemanticMatching") {
        expected = false;
        invalid = "true";
        valid = false;
      }
      && harnessOption "workSemanticMatching" null == null;

    # A row marked `ignored` removes the key from every surface built from the
    # reconciled entries, not just from the library's own result.
    ignored-row-is-not-an-option =
      !(withIgnoredRows.harnessSettingsOptions ? httpProxy)
      && !(withIgnoredRows.settingsOptions ? llmEndpoint)
      && !(lib.elem "httpProxy" withIgnoredRows.userScopeHarnessKeys)
      && completeNative withIgnoredRows;

    # The sidecar's derived inert flag, not a hand list, removes the option.
    inert-keys-follow-the-sidecar =
      lib.all (key: real.report.excluded.settings ? ${key} && !(real.settingsOptions ? ${key})) ["maxToolResultChars" "mcpSearch" "mcpSearchLimit"]
      && withConsumedInertKey.settingsOptions ? mcpSearchLimit;

    # The same restriction through the real module, on the option a normalized
    # `ai.settings.reasoningEffort` lowers into.
    module-rejects-an-invalid-enum = rejectsChange (value: (hmHarness {defaultThinkingLevel = value;}).defaultThinkingLevel) {
      expected = "high";
      invalid = "bogus";
      valid = "high";
    };

    nested-types-follow-the-sidecar = let
      autoResume = input: (harnessOption "fermentV2" input).autoResume;
      validFerment = {autoResume = true;};
    in
      checkRows "native nested settings" {
        "fermentV2 rejects a scalar in place of an object" = rejectsChange autoResume {
          expected = true;
          invalid = true;
          valid = validFerment;
        };
        "fermentV2 rejects undeclared fields" = rejectsChange autoResume {
          expected = true;
          invalid = validFerment // {probe = true;};
          valid = validFerment;
        };
        "statusLine.pinned rejects unknown list members" = rejectsChange (input: (harnessOption "statusLine" {pinned = input;}).pinned) {
          expected = ["model"];
          invalid = ["probe"];
          valid = ["model"];
        };
      };

    # The portable effort values must all reach the generated option unchanged.
    normalized-effort-lowers-into-native = checkRows "portable effort value" (
      lib.genAttrs portableEfforts (value: loweredEffort value == value)
      // {"every portable effort has a lowering row" = sorted declaredEfforts == portableEfforts;}
    );

    option-notes-are-current =
      real.report.staleNotes
      == []
      && withoutSkillPaths.report.staleNotes == ["settings.skillPaths"];

    own-environment-names-are-extracted = rejectsChange (surface: surface.environmentName "KIMCHI_REGION") {
      expected = "KIMCHI_REGION";
      invalid = withoutOwnVariable;
      valid = real;
    };

    # Per-key `project` and projectTier.honoredKeys are two readings of one
    # extraction; the devenv rejection uses the first.
    project-tier-rejects-user-scope-config =
      sorted real.userScopeConfigKeys
      == sorted (lib.subtractLists (get aggregate "config.projectTier").honoredKeys (builtins.attrNames real.rules.results.config.entries))
      && lib.any (lib.hasInfix "config.json keys Kimchi reads only from user scope: telemetry") (failedAssertions devenvTelemetry)
      && failedAssertions hmTelemetry == [];

    # A reconciled key cannot silently vanish or become an undocumented option.
    reconciled-keys-have-exactly-one-destination = completeNative real;

    removed-key-fails-its-consumer = rejectsChange (options: (mergeNative options {llmEndpoint = "https://example.invalid";}).llmEndpoint) {
      expected = "https://example.invalid";
      invalid = fixture.settingsOptions;
      valid = real.settingsOptions;
    };

    # Each key is extracted separately; one key losing either union arm is a
    # regression even if the other keys' unions remain intact.
    scalar-unions-follow-the-sidecar = checkRows "native scalar unions" (lib.mapAttrs (name: sentinel:
      checkRows name {
        "rejects a boolean arm" = rejectsChange (harnessOption name) {
          expected = 25;
          invalid = true;
          valid = 25;
        };
        "string arm permits only its sentinel" = rejectsChange (harnessOption name) {
          expected = sentinel;
          invalid = "probe";
          valid = sentinel;
        };
      }) {
      fullscreenWheelScrollLines = "auto";
      httpIdleTimeoutMs = "disabled";
      websocketConnectTimeoutMs = "disabled";
    });

    # A raw credential must not become a regular option that writes to the store.
    secrets-stay-out-of-native-settings = lib.all (key:
      real.report.excluded.settings ? ${key} && !(real.settingsOptions ? ${key}))
    ["apiKey" "api_key" "gitTokens"];

    # The devenv rejection list is the sidecar's per-key scope, including
    # Kimchi's own additions and pi's global-only keys a hand list once
    # missed.
    user-scope-harness-follows-the-sidecar =
      lib.all (key: lib.elem key real.userScopeHarnessKeys) ["httpProxy" "lastTerminalWarnings" "sessionNameModel" "workSemanticMatching"]
      && !(lib.elem "defaultThinkingLevel" real.userScopeHarnessKeys)
      && !(lib.elem "theme" real.userScopeHarnessKeys)
      && lib.elem "theme" withUserScopeTheme.userScopeHarnessKeys
      && lib.all (key: real.harnessSettingsOptions ? ${key}) real.userScopeHarnessKeys;
  };
in {
  checks.kimchi-native-options = harness.mkTest "kimchi-native-options" (checkRows "native options" cases);
}
