# `ai.kimchi.native.*` follows packages/kimchi/extracted.json.
#
# The option types are generated from the committed sidecar by
# ../lib/extracted.nix. Agreement with the real sidecar alone would also hold
# for a hand-copied option list, so the cases that matter run the same
# generator over a FIXTURE sidecar — one key added, one removed, one enum
# widened — and require the option surface to move with it. Each case is named
# in the failure message.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm ownedDocument;
  committed = builtins.fromJSON (builtins.readFile ../extracted.json);
  surfaceFor = extracted: import ../lib/extracted.nix {inherit extracted lib pkgs;};
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
  withoutOwnVariable = surfaceFor (lib.recursiveUpdate committed {
    environment.variables.KIMCHI_NO_UPDATE_CHECK.consumerOverridable = false;
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
  hmHarness = harnessSettings:
    (ownedDocument "kimchi" ".config/kimchi/harness/settings.json" (evalHm {
      ai.kimchi = {
        enable = true;
        native = {inherit harnessSettings;};
      };
    }))
    .value;
  forced = value: (builtins.tryEval (builtins.deepSeq value true)).success;

  # The normalized effort enum, read off the option rather than restated.
  normalizedEfforts =
    ((evalHm {}).options.ai.settings.type.getSubOptions []).reasoningEffort.type.nestedTypes.elemType.functor.payload.values;
  loweredEffort = effort:
    (ownedDocument "kimchi" ".config/kimchi/harness/settings.json" (evalHm {
      ai = {
        kimchi.enable = true;
        settings.reasoningEffort = effort;
      };
    }))
    .value
    .defaultThinkingLevel
    or null;

  keptKeys = surface: excluded: sorted (builtins.attrNames (builtins.removeAttrs surface.keys (builtins.attrNames excluded)));

  devenvTelemetry = evalDevenv {
    ai.kimchi = {
      enable = true;
      native.settings.telemetry.enabled = false;
    };
  };
  hmTelemetry = evalHm {
    ai.kimchi = {
      enable = true;
      native.settings.telemetry.enabled = false;
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
      == keptKeys committed.config real.report.excluded.settings
      && sorted (builtins.attrNames real.harnessSettingsOptions)
      == keptKeys committed.harness real.report.excluded.harnessSettings
      && real.report.excluded.settings ? apiKey
      && real.report.excluded.settings ? api_key;

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
      real.report.staleExclusions
      == []
      && real.report.staleNotes == []
      && real.report.staleRefinements == []
      && withoutModelRoles.report.staleRefinements == ["harnessSettings.modelRoles"]
      # The hand-kept user-scope harness list names only keys Kimchi reads.
      && lib.all (key: real.harnessSettingsOptions ? ${key}) (import ../lib/user-scope-only-harness-settings.nix);

    every-type-is-mapped =
      real.report.untyped
      == []
      && withUnion.report.untyped == ["harnessSettings.probeUnion"];

    # Per-key `project` and projectTier.honoredKeys are two readings of one
    # extraction; the devenv rejection uses the first.
    project-tier-rejects-user-scope-config =
      sorted real.userScopeConfigKeys
      == sorted (lib.subtractLists committed.config.projectTier.honoredKeys (builtins.attrNames committed.config.keys))
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
      real.environmentName "KIMCHI_NO_UPDATE_CHECK"
      == "KIMCHI_NO_UPDATE_CHECK"
      && !(forced (withoutOwnVariable.environmentName "KIMCHI_NO_UPDATE_CHECK"));
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
