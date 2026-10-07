# `ai.kimchi.native.*` follows packages/kimchi/extracted.json.
#
# The option types are generated from the committed sidecar by
# ../lib/extracted.nix. Agreement with the real sidecar alone would also hold
# for a hand-copied option list, so the cases that matter run the same
# generator over a FIXTURE sidecar — one key added, one removed, one enum
# widened — and require the option surface to move with it. Each case is named
# in the failure message.
{
  extractedLib,
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv;
  evalHm = config: harness.evalHm (lib.mkMerge [{ai.kimchi.native.settings.region = lib.mkOverride 1200 "us";} config]);
  committed = builtins.fromJSON (builtins.readFile ../extracted.json);
  surfaceFor = extracted: import ../lib/extracted.nix {inherit extracted extractedLib lib pkgs;};
  real = surfaceFor committed;
  sorted = lib.sort (a: b: a < b);

  # One harness key added, one config key removed, one enum value added.
  fixture = surfaceFor (lib.recursiveUpdate (committed
    // {
      config = committed.config // {keys = builtins.removeAttrs committed.config.keys ["llmEndpoint"];};
    }) {
    harness.keys = {
      doubleEscapeAction.enum = committed.harness.keys.doubleEscapeAction.enum ++ ["probe"];
      probeAdded = {
        optional = true;
        type = "boolean";
        typeExpression = "boolean";
      };
    };
  });
  # Guards the fixture itself: recursiveUpdate cannot delete a key.
  fixtureHasNoLlmEndpoint = !(fixture.settingsOptions ? llmEndpoint);

  # A hand-table row whose path is gone, and a key whose type nothing maps.
  withoutModelRoles = surfaceFor (committed
    // {
      harness = committed.harness // {keys = builtins.removeAttrs committed.harness.keys ["modelRoles"];};
    });
  withUnion = surfaceFor (lib.recursiveUpdate committed {
    harness.keys.probeUnion = {
      optional = true;
      type = "union";
      typeExpression = "string | number";
    };
  });
  withUserScopeTheme = surfaceFor (lib.recursiveUpdate committed {
    harness.keys.theme.project = false;
  });
  withConsumedInertKey = surfaceFor (lib.recursiveUpdate committed {
    config.keys.mcpSearchLimit.inert = false;
  });
  withoutOwnVariable = surfaceFor (lib.recursiveUpdate committed {
    environment.variables.KIMCHI_REGION.consumerOverridable = false;
  });

  # Does `value` type-check against a closed submodule of `options`?
  accepts = options: value:
    (builtins.tryEval (builtins.deepSeq
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
      })
      .config
      .native
      true))
    .success;

  failedAssertions = evaluated: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) evaluated.config.assertions);
  # The user harness settings.json Home Manager copies, decoded.
  hmHarnessSettings = evaluated:
    evaluated.config.ai.kimchi.files."${evaluated.config.ai.kimchi.configDir}/harness/settings.json".content.value;
  hmHarness = harnessSettings:
    hmHarnessSettings (evalHm {
      ai.kimchi = {
        enable = true;
        native = {inherit harnessSettings;};
      };
    });
  forced = value: (builtins.tryEval (builtins.deepSeq value true)).success;

  # The normalized effort enum, read off the option rather than restated.
  normalizedEfforts =
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

  keptKeys = keys: excluded: sorted (builtins.attrNames (builtins.removeAttrs keys (builtins.attrNames excluded)));

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

  cases = {
    # Every key the sidecar keeps is an option, and nothing else is.
    real-surface-is-the-sidecar =
      sorted (builtins.attrNames real.settingsOptions)
      == keptKeys real.rules.results.config.entries real.report.excluded.settings
      && sorted (builtins.attrNames real.harnessSettingsOptions)
      == keptKeys real.rules.results.harness.entries real.report.excluded.harnessSettings
      && real.report.excluded.settings ? apiKey
      && real.report.excluded.settings ? api_key
      && real.report.excluded.settings ? gitTokens;

    added-key-appears =
      fixture.harnessSettingsOptions ? probeAdded
      && accepts fixture.harnessSettingsOptions {probeAdded = true;}
      && !(accepts real.harnessSettingsOptions {probeAdded = true;});

    removed-key-fails-its-consumer =
      fixtureHasNoLlmEndpoint
      && accepts real.settingsOptions {llmEndpoint = "https://example.invalid";}
      && !(accepts fixture.settingsOptions {llmEndpoint = "https://example.invalid";});

    enum-follows-the-sidecar =
      accepts fixture.harnessSettingsOptions {doubleEscapeAction = "probe";}
      && !(accepts real.harnessSettingsOptions {doubleEscapeAction = "probe";})
      && accepts real.harnessSettingsOptions {doubleEscapeAction = "tree";};

    # The same rejection through the real module, on the option a normalized
    # `ai.settings.reasoningEffort` lowers into.
    module-rejects-an-invalid-enum =
      !(forced (hmHarness {defaultThinkingLevel = "bogus";}))
      && (hmHarness {defaultThinkingLevel = "high";}).defaultThinkingLevel == "high";

    # Normalized `ai.settings` converts INTO the typed native option, so every
    # normalized value must be one the extracted enum accepts.
    normalized-effort-lowers-into-native =
      normalizedEfforts
      != []
      && lib.all (effort: forced (loweredEffort effort) && loweredEffort effort == effort) normalizedEfforts;

    nested-types-follow-the-sidecar =
      accepts real.harnessSettingsOptions {fermentV2.autoResume = true;}
      && !(accepts real.harnessSettingsOptions {fermentV2 = true;})
      && !(accepts real.harnessSettingsOptions {fermentV2.probe = true;})
      && accepts real.harnessSettingsOptions {statusLine.pinned = ["model"];}
      && !(accepts real.harnessSettingsOptions {statusLine.pinned = ["probe"];});

    hand-tables-are-current =
      real.report.staleNotes
      == []
      && real.report.staleRefinements == []
      && withoutModelRoles.report.staleRefinements == ["harnessSettings.modelRoles"];

    # The devenv rejection list is the sidecar's per-key scope, including
    # Kimchi's own additions and pi's global-only keys a hand list once
    # missed.
    user-scope-harness-follows-the-sidecar =
      lib.all (key: lib.elem key real.userScopeHarnessKeys) ["defaultProjectTrust" "httpProxy" "lastTerminalWarnings" "modelRoles"]
      && !(lib.elem "defaultThinkingLevel" real.userScopeHarnessKeys)
      && !(lib.elem "theme" real.userScopeHarnessKeys)
      && lib.elem "theme" withUserScopeTheme.userScopeHarnessKeys
      && lib.all (key: real.harnessSettingsOptions ? ${key}) real.userScopeHarnessKeys;

    # The sidecar's derived inert flag, not a hand list, removes the option.
    inert-keys-follow-the-sidecar =
      lib.all (key: real.report.excluded.settings ? ${key} && !(real.settingsOptions ? ${key})) ["maxToolResultChars" "mcpSearch" "mcpSearchLimit"]
      && withConsumedInertKey.settingsOptions ? mcpSearchLimit;

    every-type-is-mapped =
      real.report.untyped
      == []
      && withUnion.report.untyped == ["harnessSettings.probeUnion"];

    # Per-key `project` and projectTier.honoredKeys are two readings of one
    # extraction; the devenv rejection uses the first.
    project-tier-rejects-user-scope-config =
      sorted real.userScopeConfigKeys
      == sorted (lib.subtractLists committed.config.projectTier.honoredKeys (builtins.attrNames real.rules.results.config.entries))
      && lib.any (lib.hasInfix "config.json keys Kimchi reads only from user scope: telemetry") (failedAssertions devenvTelemetry)
      && failedAssertions hmTelemetry == [];

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

    own-environment-names-are-extracted =
      real.environmentName "KIMCHI_REGION"
      == "KIMCHI_REGION"
      && !(forced (withoutOwnVariable.environmentName "KIMCHI_REGION"));
  };
  failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) cases);
in {
  checks.kimchi-native-options =
    if failed == []
    then
      pkgs.writeText "kimchi-native-options"
      (lib.concatMapStringsSep "\n" (name: "PASS ${name}") (builtins.attrNames cases) + "\n")
    else throw "kimchi-native-options: FAILED ${lib.concatStringsSep ", " failed}";
}
