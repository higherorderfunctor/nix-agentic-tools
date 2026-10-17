# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  extractedLib,
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv fromGeneratedTree markdownInput mkTest ownedDocument;
  evalHm = config: harness.evalHm (lib.mkMerge [{ai.kimchi.native.settings.region = lib.mkOverride 1200 "us";} config]);
  redact = import ../../../lib/redact {inherit lib;};
  workflows = pkgs.ai.kimchiExtensions.kimchi-workflows;
  workflowsHarness = ".config/kimchi/harness";
  # Reuse these module evaluations for the structural check and runtime smoke.
  backends = map (backend:
    backend
    // {
      one = backend.evaluate {
        ai.kimchi = {
          enable = true;
          extensions = {inherit workflows;};
        };
      };
    }) [
    {
      name = "global";
      evaluate = evalHm;
      settings = hmHarnessSettings;
    }
    {
      name = "project";
      evaluate = evalDevenv;
      settings = projectHarnessSettings;
    }
  ];
  # The Home Manager user config.json shared document.
  hmConfigDocument = evaluated: let
    path = "${evaluated.config.ai.kimchi.configDir}/config.json";
  in
    ownedDocument "kimchi" path evaluated;
  # Read the final structured values after staged defaults and overrides merge.
  fileValue = path: evaluated: evaluated.config.ai.files.${path}.content.value;
  hmHarnessSettings = evaluated:
    fileValue "${evaluated.config.ai.kimchi.configDir}/harness/settings.json" evaluated;
  projectHarnessSettings = evaluated:
    if evaluated.config.ai.files ? ".config/kimchi/harness/settings.json"
    then fileValue ".config/kimchi/harness/settings.json" evaluated
    else {};
  # What Home Manager owns in the user config.json and harness settings.json
  # when nothing is set: policy and integration defaults only.
  userConfigDefaults = {
    region = "us";
    skillPaths = [".config/kimchi/harness/skills" ".pi/agent/skills" ".claude/skills"];
    telemetry.enabled = false;
  };
  userHarnessDefaults = {
    defaultModel = "auto";
    defaultProjectTrust = "never";
    defaultProvider = "kimchi-dev";
    enableInstallTelemetry = false;
    theme = "kimchi-minimal";
  };
  # The keys and boolean samples come from the sidecar; other shapes need a
  # deliberate sample so a new user-scope key cannot pass unnoticed.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  inherit (facts) get;
  inherit (facts.load {dir = ../extracted;}) aggregate;
  userScopeOnlyHarnessSettingKeys =
    (import ../lib/extracted.nix {
      inherit aggregate extractedLib lib pkgs;
    }).userScopeHarnessKeys;
  userScopeOnlyHarnessSettingValues = {
    defaultProjectTrust = "always";
    fermentV2.autoResume = true;
    httpProxy = "http://proxy.invalid:3128";
    lastTerminalWarnings.kitty = "0.35.0";
    modelMetadata.example.description = "Example model";
    modelRoles.builder = "provider/model";
    statusLine.pinned = ["model"];
  };
  userScopeOnlyHarnessSettingValue = key:
    if (get aggregate "harness.keys.${key}").type == "boolean"
    then true
    else userScopeOnlyHarnessSettingValues.${key} or (throw "packages/kimchi/checks/module-eval.nix: add a sample value for the user-scope harness key ${key}");
  kimchiStub = pkgs.writeShellScriptBin "kimchi" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
  exactCwdProjectRoot = pkgs.runCommand "kimchi-exact-cwd-project-root" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.coreutils}/bin/mkdir -p "$out/subdir"
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
  agentConfig = {
    ai = {
      agents.reviewer = {
        description = "Reviews code";
        instructions.text = "BODY";
      };
      kimchi = {
        enable = true;
        agents.native = nativeAgent;
      };
    };
  };
  hmAgentsDir = ".config/kimchi/harness/agents";
  devenvAgentsDir = ".kimchi/agents";
  agentFiles = dir: evaluated:
    lib.filterAttrs (path: _: lib.hasPrefix "${dir}/" path) (deliveredFiles evaluated.config);
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
            native.harnessSettings = lib.setAttrByPath [key] (userScopeOnlyHarnessSettingValue key);
          };
        };
        failed = builtins.filter (entry: !entry.assertion) rejected.config.assertions;
        failureMessage =
          if builtins.length failed == 1
          then (builtins.head failed).message
          else null;
        rejectedAttempt = builtins.tryEval (builtins.deepSeq (checkModuleAssertions rejected) true);
        hmAcceptedAttempt = builtins.tryEval (builtins.deepSeq
          (hmHarnessSettings (evalHm {
            ai.kimchi = {
              enable = true;
              native.harnessSettings = lib.setAttrByPath [key] (userScopeOnlyHarnessSettingValue key);
            };
          }))
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
          && lib.hasInfix "Set these with Home Manager" failureMessage;
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
    # Exceptions with their own checks: defaultProjectTrust below, and
    # `resources`, which devenv delivers through KIMCHI_ENABLE_RESOURCES.
    (lib.subtractLists ["defaultProjectTrust" "resources"] userScopeOnlyHarnessSettingKeys));

  hmDefaultProjectTrustChecks = let
    failures = value:
      failedAssertions (evalHm {
        ai.kimchi = {
          enable = true;
          native.harnessSettings.defaultProjectTrust = value;
        };
      });
    invalid = [
      {
        name = "always";
        value = "always";
      }
      {
        name = "ask";
        value = "ask";
      }
      {
        name = "null";
        value = null;
      }
    ];
    rejects = entry: let
      messages = failures entry.value;
    in {
      name = "module-kimchi-hm-rejects-default-project-trust-${entry.name}";
      value = mkTest "kimchi-hm-rejects-default-project-trust-${entry.name}" (
        builtins.length messages
        == 1
        && lib.hasInfix "native.harnessSettings.defaultProjectTrust must be \"never\"" (builtins.head messages)
        && lib.hasInfix "ai.kimchi.projectTrust" (builtins.head messages)
      );
    };
  in
    lib.listToAttrs (map rejects invalid)
    // {
      module-kimchi-hm-accepts-default-project-trust-never = mkTest "kimchi-hm-accepts-default-project-trust-never" (
        failures "never" == []
      );
    };
in {
  imports = [
    {checks = hmDefaultProjectTrustChecks;}
    {checks = userScopeOnlyHarnessSettingChecks;}
  ];

  checks = {
    # Both backends' launchers warn from the launch directory, so the notice
    # reaches Home Manager-only users in any repo. Each launcher is paired
    # with the user harness it reads trust from: Home Manager's follows
    # configDir.
    module-kimchi-project-trust-notice = let
      hmLauncher = kimchi:
        lib.head
        (evalHm {
          ai.kimchi =
            {
              enable = true;
              package = kimchiStub;
            }
            // kimchi;
        }).config.home.packages;
      launchers = lib.concatMap ({
        launcher,
        harness,
      }: ["${launcher}/bin/kimchi" harness]) [
        {
          launcher = hmLauncher {};
          harness = ".config/kimchi/harness";
        }
        {
          launcher = hmLauncher {configDir = "custom/kimchi";};
          harness = "custom/kimchi/harness";
        }
        {
          launcher =
            lib.head
            (evalDevenv {
              ai.kimchi = {
                enable = true;
                package = kimchiStub;
              };
            }).config.packages;
          harness = ".config/kimchi/harness";
        }
      ];
    in
      pkgs.runCommand "module-test-kimchi-project-trust-notice" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./project-trust-notice-test.py} ${lib.escapeShellArgs launchers}
        echo PASS > "$out"
      '';

    # Slash commands dispatch before model/credential validation. Feed the
    # smoke production delivery, including HM's serialized shared-document
    # declaration and devenv's rendered settings file in the generated tree.
    kimchi-workflows-smoke = let
      delivered =
        map (backend: let
          files = deliveredFiles backend.one.config;
          settingsPath = "${workflowsHarness}/settings.json";
          settings =
            if backend.name == "global"
            then
              pkgs.writeText "kimchi-workflows-global-settings.json"
              (builtins.toJSON (fileValue settingsPath backend.one))
            else files.${settingsPath}.rendered;
        in {
          inherit (backend) name;
          inherit settings;
          extension = files."${workflowsHarness}/packages/workflows".source;
        })
        backends;
    in
      pkgs.runCommand "kimchi-workflows-smoke" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./workflows-smoke.py} ${pkgs.ai.kimchi}/bin/kimchi ${workflows} ${./workflows-observer.ts} \
          ${pkgs.writeText "kimchi-workflows-delivery.json" (builtins.toJSON delivered)}
        echo PASS > "$out"
      '';

    module-kimchi-external-workflows = mkTest "kimchi-external-workflows" (
      let
        checkBackend = {
          evaluate,
          one,
          settings,
          ...
        }: let
          withExtensions = extensions:
            evaluate {
              ai.kimchi = {
                enable = true;
                inherit extensions;
                native.harnessSettings.packages = ["/consumer/package"];
              };
            };
          empty = evaluate {ai.kimchi.enable = true;};
          two = withExtensions {
            another = workflows;
            inherit workflows;
          };
          extensionFiles = evaluated:
            lib.filterAttrs (path: _: lib.hasPrefix "${workflowsHarness}/packages/" path) (deliveredFiles evaluated.config);
          checkLinks = evaluated: names:
            builtins.attrNames (extensionFiles evaluated)
            == map (name: "${workflowsHarness}/packages/${name}") names
            && !(lib.any (lib.hasPrefix "${workflowsHarness}/extensions/") (builtins.attrNames (deliveredFiles evaluated.config)))
            && lib.all (name: let
              path = "${workflowsHarness}/packages/${name}";
              file = (extensionFiles evaluated).${path};
            in
              fromGeneratedTree path file
              && builtins.hasContext file.source
              && !(file.recursive or false)
              && evaluated.config.ai.kimchi._generatedFiles ? ${path}
              && evaluated.config.ai.files.${path}.method == "symlink"
              && evaluated.config.ai.filesOwners.${path} == ["kimchi"])
            names;
          rejected = builtins.tryEval (builtins.deepSeq (withExtensions {workflows = "${workflows}";}).config.ai.kimchi.extensions true);
        in
          lib.all (evaluated: lib.all (assertion: assertion.assertion) evaluated.config.assertions) [empty one two]
          && extensionFiles empty == {}
          && !((settings empty) ? packages)
          && checkLinks one ["workflows"]
          && checkLinks two ["another" "workflows"]
          && (settings one).packages == ["packages/workflows"]
          && lib.sort builtins.lessThan (settings two).packages == ["/consumer/package" "packages/another" "packages/workflows"]
          && !rejected.success;
      in
        lib.all checkBackend backends
    );

    module-kimchi-shell = mkTest "kimchi-shell" (
      lib.all (backend: let
        check = config: expected: let
          evaluated = backend.evaluate (lib.mkMerge [{ai.kimchi.enable = true;} config]);
          settings = backend.settings evaluated;
        in
          lib.all (assertion: assertion.assertion) evaluated.config.assertions
          && (settings.shellPath or null) == expected
          && !(lib.any (lib.hasInfix "ai.shell") evaluated.config.warnings);
      in
        check {} null
        && check {ai.kimchi.shell = pkgs.bash;} (lib.getExe pkgs.bash)
        && check {ai.shell = pkgs.bash;} (lib.getExe pkgs.bash)
        && check {
          ai.shell = pkgs.bash;
          ai.kimchi.shell = null;
        } (lib.getExe pkgs.bash)
        && check {
          ai.shell = pkgs.bash;
          ai.kimchi.shell = pkgs.bashNonInteractive;
        } (lib.getExe pkgs.bashNonInteractive)
        && check {
          ai.shell = pkgs.bash;
          ai.kimchi.native.harnessSettings.shellPath = lib.getExe pkgs.bashNonInteractive;
        } (lib.getExe pkgs.bashNonInteractive))
      backends
    );

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
        fromGeneratedTree ".config/kimchi/harness/AGENTS.md" hm.config.home.file.".config/kimchi/harness/AGENTS.md"
        && (markdownInput hm ".config/kimchi/harness/AGENTS.md").text == expected
        && fromGeneratedTree "AGENTS.md" (deliveredFiles devenv.config)."AGENTS.md"
        && (markdownInput devenv "AGENTS.md").text == expected
    );

    module-kimchi-rules-agentsmd = mkTest "kimchi-rules-agentsmd" (
      let
        config.ai = {
          kimchi.enable = true;
          rules = {
            always.text = "ALWAYS-RULE.";
            scoped = {
              matcher = ["src/**"];
              references = ["docs/scoped.md"];
              text = "SCOPED-RULE-BODY.";
            };
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmAgents = (markdownInput hm ".config/kimchi/harness/AGENTS.md").text;
        projectAgents = (markdownInput devenv "AGENTS.md").text;
      in
        hmAgents
        == projectAgents
        && lib.hasInfix "## Path-scoped rules" projectAgents
        && lib.hasInfix "Match:\n    - `src/**`" projectAgents
        && lib.hasInfix "[`docs/scoped.md`](docs/scoped.md)" projectAgents
        && lib.hasInfix "<!-- rule: always -->\n\nALWAYS-RULE." projectAgents
        && !(lib.hasInfix "SCOPED-RULE-BODY." projectAgents)
        && devenv.config.ai.internal.agentsMd."AGENTS.md".index ? scoped
        && !(devenv.config.ai.internal.agentsMd."AGENTS.md".rules ? scoped)
    );

    module-kimchi-rules-dedupe-with-codex = mkTest "kimchi-rules-dedupe-with-codex" (
      let
        evaluated = evalDevenv {
          ai = {
            codex.enable = true;
            kimchi.enable = true;
            rules.shared.text = "SHARED-RULE.";
          };
        };
      in
        (markdownInput evaluated "AGENTS.md").text
        == "<!-- rule: shared -->\n\nSHARED-RULE."
    );

    module-kimchi-rules-on-demand-index = mkTest "kimchi-rules-on-demand-index" (
      let
        evaluated = evalDevenv {
          ai = {
            kimchi.enable = true;
            rules.semantic = {
              description = "Load for semantic work";
              inclusion = ["auto"];
              references = ["docs/semantic.md"];
              text = "SEMANTIC-RULE-BODY.";
            };
          };
        };
        agents = (markdownInput evaluated "AGENTS.md").text;
      in
        lib.hasInfix "## Rule index" agents
        && lib.hasInfix "Trigger: `auto`" agents
        && lib.hasInfix "Description: Load for semantic work" agents
        && lib.hasInfix "[`docs/semantic.md`](docs/semantic.md)" agents
        && !(lib.hasInfix "SEMANTIC-RULE-BODY." agents)
        && evaluated.config.ai.internal.agentsMd."AGENTS.md".hasOnDemandIndex
    );

    # tryEval cannot expose a throw message. Evaluate the resolver in a
    # subprocess so the diagnostic itself stays part of the contract.
    module-kimchi-rules-on-demand-needs-references = let
      probe = pkgs.writeText "kimchi-rule-inclusion.nix" ''
        { withReferences ? false }:
        let
          lib = import ${pkgs.path}/lib;
          aiCommon = import ${../../../lib/ai/ai-common.nix} { inherit lib; };
        in
          aiCommon.resolveInclusion {
            name = "semantic";
            rule = {
              description = "Load for semantic work";
              inclusion = ["auto"];
              matcher = null;
              references = if withReferences then ["docs/semantic.md"] else [];
            };
            runtime = "kimchi";
          }
      '';
    in
      pkgs.runCommandLocal "module-test-kimchi-rules-on-demand-needs-references" {
        nativeBuildInputs = [pkgs.nix];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export NIX_STATE_DIR="$TMPDIR/nix-state"
        export USER="''${USER:-nixbld}"
        mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
        test "$(nix-instantiate --eval --strict ${probe} --arg withReferences true)" = '"auto"'
        if nix-instantiate --eval --strict ${probe} --arg withReferences false >actual.stdout 2>actual.stderr; then
          echo "FAIL: Kimchi auto rule without references unexpectedly succeeded" >&2
          exit 1
        fi
        grep -F "runtime 'kimchi'" actual.stderr
        grep -F 'requested inclusion priority list ["auto"] has no supported trigger' actual.stderr
        touch "$out"
      '';

    # ── Kimchi (mkRuntime factory participant) ──────────────────────────
    module-kimchi-default-disabled = mkTest "kimchi-default-disabled" (!(evalHm {}).config.ai.kimchi.enable);

    module-kimchi-enable-toggles = mkTest "kimchi-enable-toggles" (evalHm {ai.kimchi.enable = true;}).config.ai.kimchi.enable;

    module-kimchi-package-null-skips-install-keeps-files = mkTest "kimchi-package-null-skips-install-keeps-files" (
      let
        config.ai.kimchi = {
          enable = true;
          package = null;
          native.settings.redaction.enabled = false;
        };
        devenv = evalDevenv config;
        hm = evalHm config;
      in
        devenv.config.packages
        == []
        && hm.config.home.packages == []
        && fileValue ".kimchi/config.json" devenv
        == {
          redaction.enabled = false;
        }
        && (hmConfigDocument hm).value.redaction.enabled == false
    );

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
        text = builtins.toJSON (fileValue ".kimchi/config.json" result);
      in
        lib.hasInfix ''"redaction":{"enabled":false}'' text
        && !lib.hasInfix "redaction.enabled" text
    );

    # Parity: the same config.json surface triggers the HM shared writer.
    module-kimchi-config-json-hm-copy = mkTest "kimchi-config-json-hm-copy" (
      let
        result = evalHm {
          ai.kimchi = {
            enable = true;
            native.settings.telemetry.enabled = false;
          };
        };
      in
        result.config.ai.files.".config/kimchi/config.json".method
        == "rw"
        && (hmConfigDocument result).value.telemetry.enabled == false
    );

    # Home Manager shares its two writable documents; remaining JSON copies
    # stay read-only. Empty devenv declarations deliver no project file.
    module-kimchi-hm-owns-user-files = mkTest "kimchi-hm-owns-user-files" (
      let
        evaluated = evalHm {ai.kimchi.enable = true;};
        plan = evaluated.config.ai.files;
        devenv = evalDevenv {ai.kimchi.enable = true;};
      in
        (hmConfigDocument evaluated).value
        == userConfigDefaults
        && lib.all (path: plan.${path}.method == "rw" && plan.${path}.mode == null)
        [".config/kimchi/config.json" ".config/kimchi/harness/settings.json"]
        && hmHarnessSettings evaluated == userHarnessDefaults
        && lib.all (name: let entry = plan.${".config/kimchi/harness/${name}.json"}; in entry.method == "ro" && entry.mode == null)
        ["mcp" "permissions" "trust"]
        && fileValue ".config/kimchi/harness/mcp.json" evaluated == {}
        && fileValue ".config/kimchi/harness/permissions.json" evaluated == {}
        && !(lib.any (lib.hasPrefix ".config/kimchi/harness/") (builtins.attrNames evaluated.config.home.file))
        && devenv.config.ai.files == {}
    );

    module-kimchi-hm-requires-region = mkTest "kimchi-hm-requires-region" (
      let
        missing = harness.evalHm {ai.kimchi.enable = true;};
      in
        lib.elem "ai.kimchi.native.settings.region is required with Home Manager; declare the account region (us or eu)." (failedAssertions missing)
    );

    # The policy settings are defaults: a declaration replaces each one, and
    # the two Kimchi reads from its environment follow the declaration. They
    # live in the HM settings option TYPE, so a whole-attrset definition
    # competes per key too: at mkDefault it still replaces each default, and
    # at mkForce it keeps every default it does not name.
    module-kimchi-user-config-defaults-override = mkTest "kimchi-user-config-defaults-override" (
      let
        declared = {
          preferences.hideTips = true;
          region = "eu";
          skillPaths = [".custom/skills"];
          telemetry.enabled = false;
        };
        withSettings = settings:
          harness.evalHm {
            ai.kimchi = {
              enable = true;
              native.settings = settings;
              native.harnessSettings.hideThinkingBlock = false;
            };
          };
        evaluated = withSettings declared;
      in
        (hmConfigDocument evaluated).value
        == lib.recursiveUpdate userConfigDefaults declared
        && (hmConfigDocument (withSettings (lib.mkDefault declared))).value == lib.recursiveUpdate userConfigDefaults declared
        && (hmConfigDocument (withSettings (lib.mkForce {region = "eu";}))).value
        == userConfigDefaults // {region = "eu";}
        && (hmHarnessSettings evaluated).hideThinkingBlock == false
        && !(hmHarnessSettings evaluated ? quietStartup)
    );

    # Legacy identity is stable even before the first enabled generation.
    module-kimchi-hm-ledger-identity = mkTest "kimchi-hm-ledger-identity" (
      let
        configDir = "custom/kimchi";
        evaluated = evalHm {
          ai.kimchi = {
            inherit configDir;
            enable = true;
          };
        };
        disabled = evalHm {ai.kimchi = {inherit configDir;};};
        expected =
          map (path: {
            codec = "json";
            ledger = "materialize/kimchi-shared-${builtins.hashString "sha256" path}.json";
            inherit path;
          }) ["${configDir}/config.json" "${configDir}/harness/settings.json"]
          ++ map (path: {
            codec = "dir";
            ledger = "materialize/kimchi-files-${builtins.hashString "sha256" path}.manifest";
            inherit path;
          }) [configDir "${configDir}/harness" ".config/kimchi/harness"];
      in
        lib.all (item: lib.elem item evaluated.config.ai.legacyLedgers && lib.elem item disabled.config.ai.legacyLedgers) expected
        && evaluated.config.ai.kimchi.legacyLedgers == disabled.config.ai.kimchi.legacyLedgers
        && disabled.config.ai.kimchi.files == {}
    );

    # native.harnessSettings render to the project harness settings.json, a
    # read-only copy rather than a store link.
    module-kimchi-harness-settings = mkTest "kimchi-harness-settings" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            native.harnessSettings.hideThinkingBlock = true;
          };
        };
      in
        result.config.ai.files.".config/kimchi/harness/settings.json".method
        == "ro"
        && projectHarnessSettings result == {hideThinkingBlock = true;}
        && !(result.config.files ? ".config/kimchi/harness/settings.json")
    );

    # Home Manager defaults Kimchi to its Auto router. The default lives in
    # the HM harness option TYPE, so a whole-attrset definition reaches it at
    # any priority. The model pair sits at priority 1200 and is coupled: a
    # consumer who declares either half at mkDefault or stronger, null
    # included, gets neither half from the module, so a model on another
    # provider never pairs with `kimchi-dev`; a weaker declaration loses to
    # the default. Devenv adds no model default, so it must add nothing and
    # must not trip its own user-scope rejection.
    module-kimchi-auto-model-default = mkTest "kimchi-auto-model-default" (
      let
        hmHarness = harnessSettings:
          hmHarnessSettings (evalHm {
            ai.kimchi = {
              enable = true;
              native = {inherit harnessSettings;};
            };
          });
        pairOf = value: {
          model = value.defaultModel or null;
          provider = value.defaultProvider or null;
        };
        undeclared = hmHarness {};
        declaredPair = hmHarness {
          defaultModel = "some-model";
          defaultProvider = "some-provider";
        };
        declaredPairAtDefault = hmHarness {
          defaultModel = lib.mkDefault "some-model";
          defaultProvider = lib.mkDefault "some-provider";
        };
        modelOnly = hmHarness {defaultModel = "some-model";};
        providerOnly = hmHarness {defaultProvider = "some-provider";};
        modelNulled = hmHarness {defaultModel = null;};
        # a whole-attrset definition, at mkDefault and at mkForce, still
        # reaches the type's defaults and competes per key
        wholeDefault = hmHarness (lib.mkDefault {
          defaultModel = "some-model";
          defaultProvider = "some-provider";
        });
        wholeForce = hmHarness (lib.mkForce {theme = "dark";});
        # weaker than the default: Auto wins
        weakerPair = hmHarness {
          defaultModel = lib.mkOverride 1300 "some-model";
          defaultProvider = lib.mkOverride 1300 "some-provider";
        };
        # The shared normalized surface carries no model; its only field must
        # leave the default pair alone.
        withEffort = hmHarnessSettings (evalHm {
          ai = {
            kimchi.enable = true;
            settings.reasoningEffort = "high";
          };
        });
        devenv = evalDevenv {ai.kimchi.enable = true;};
        devenvHarness = projectHarnessSettings devenv;
      in
        # default: Auto on kimchi-dev
        pairOf undeclared
        == {
          model = "auto";
          provider = "kimchi-dev";
        }
        && pairOf withEffort
        == {
          model = "auto";
          provider = "kimchi-dev";
        }
        # a declared pair wins, at normal and at mkDefault priority
        && pairOf declaredPair
        == {
          model = "some-model";
          provider = "some-provider";
        }
        && pairOf declaredPairAtDefault
        == {
          model = "some-model";
          provider = "some-provider";
        }
        # one declared half drops both module halves: no mismatched pair
        && pairOf modelOnly
        == {
          model = "some-model";
          provider = null;
        }
        && pairOf providerOnly
        == {
          model = null;
          provider = "some-provider";
        }
        && pairOf modelNulled
        == {
          model = null;
          provider = null;
        }
        && pairOf wholeDefault
        == {
          model = "some-model";
          provider = "some-provider";
        }
        && pairOf wholeForce
        == {
          model = "auto";
          provider = "kimchi-dev";
        }
        && wholeForce.theme or null == "dark"
        && pairOf weakerPair
        == {
          model = "auto";
          provider = "kimchi-dev";
        }
        # devenv: no model default in the project file, and no assertion
        # fires
        && !(devenvHarness ? defaultModel)
        && !(devenvHarness ? defaultProvider)
        && failedAssertions devenv == []
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
        (hmHarnessSettings (evalHm config)).defaultThinkingLevel
        or null
        == "high"
        && (projectHarnessSettings (evalDevenv config)).defaultThinkingLevel or null == "high"
        && (projectHarnessSettings overridden).defaultThinkingLevel or null == "low"
    );

    # mcp.json is a read-only copy on both backends: Kimchi renames its MCP
    # edits over the path (first-run migration, ACP import, `/mcp
    # enable|disable`), which would replace a store symlink. Home Manager owns
    # the user file with no servers too; devenv claims the project file only
    # for a declared server.
    module-kimchi-mcp-copies = mkTest "kimchi-mcp-copies" (
      let
        config.ai = {
          kimchi.enable = true;
          mcpServers.example = {
            package = pkgs.hello;
            command = "hello";
            type = "stdio";
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        emptyHm = evalHm {ai.kimchi.enable = true;};
        emptyDevenv = evalDevenv {ai.kimchi.enable = true;};
      in
        (fileValue ".config/kimchi/harness/mcp.json" hm).mcpServers.example.command
        == "hello"
        && !(hm.config.home.file ? ".config/kimchi/harness/mcp.json")
        && (fileValue ".kimchi/mcp.json" devenv).mcpServers.example.command == "hello"
        && !(devenv.config.files ? ".kimchi/mcp.json")
        && fileValue ".config/kimchi/harness/mcp.json" emptyHm == {}
        && !(emptyDevenv.config.ai.files ? ".kimchi/mcp.json")
    );

    # Kimchi 1.1.37 accepts a role value only as a provider/model string, or
    # for delegable roles a non-empty list of them
    # (src/extensions/orchestration/model-roles.ts:117-181). Anything else is
    # discarded with a warning at runtime, so the option type rejects it. The
    # role names, and which roles take one string, come from
    # packages/kimchi/extracted/ harness.keys.modelRoles.
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
        && (hmHarnessSettings rendered).modelRoles
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

    # Kimchi 1.1.37 reads `projectExtras.skillPaths ?? globalExtras.skillPaths`
    # (src/config.ts:526): a project `[]` replaces the user's global list, so
    # an undeclared skillPaths must leave the key out of .kimchi/config.json.
    # An explicit list, empty included, still lands.
    module-kimchi-skill-paths-inherit = mkTest "kimchi-skill-paths-inherit" (
      let
        withPaths = extra:
          evalDevenv {
            ai.kimchi =
              {
                enable = true;
              }
              // extra;
          };
      in
        !((withPaths {}).config.ai.files ? ".kimchi/config.json")
        && (fileValue ".kimchi/config.json" (withPaths {native.settings.skillPaths = [];})).skillPaths == []
        && (fileValue ".kimchi/config.json" (withPaths {native.settings.skillPaths = [".custom/skills"];})).skillPaths == [".custom/skills"]
    );

    # `region` and `telemetry.enabled` are user scope in config.json, but
    # Kimchi reads both from its environment first. Devenv therefore accepts
    # them, delivers them through the launcher alone and writes no project
    # config.json for them; a user-scope sibling is still rejected by name.
    module-kimchi-devenv-env-shadowed-settings = mkTest "kimchi-devenv-env-shadowed-settings" (
      let
        withSettings = settings:
          evalDevenv {
            ai.kimchi = {
              enable = true;
              native.settings = settings;
            };
          };
        shadowed = withSettings {
          region = "eu";
          telemetry.enabled = false;
        };
        withEndpoint = withSettings {
          region = "eu";
          telemetry.endpoint = "https://example.invalid";
        };
      in
        failedAssertions shadowed
        == []
        && !(shadowed.config.ai.files ? ".kimchi/config.json")
        && lib.any (lib.hasInfix "user scope: telemetry") (failedAssertions withEndpoint)
    );

    # Harness `resources` is user scope, but KIMCHI_ENABLE_RESOURCES can
    # enable a resource. Devenv accepts true values, delivers them through the
    # launcher alone and keeps them out of the project harness settings.json;
    # a false value fails by name, and Home Manager still writes the toggles
    # into the user file. module-kimchi-wrapper-builds proves the launcher
    # merges the ids with a value the caller already set.
    module-kimchi-devenv-env-shadowed-resources = mkTest "kimchi-devenv-env-shadowed-resources" (
      let
        withKimchi = kimchi:
          evalDevenv {
            ai.kimchi = {enable = true;} // kimchi;
          };
        enabled = {
          "extensions.ferment-v2" = true;
          "extensions.todos" = true;
        };
        shadowed = withKimchi {
          native.harnessSettings = {
            hideThinkingBlock = true;
            resources = enabled;
          };
        };
        resourcesOnly = withKimchi {native.harnessSettings.resources = enabled;};
        withFalse = failedAssertions (withKimchi {
          native.harnessSettings.resources = enabled // {"extensions.memory" = false;};
        });
        # A comma or whitespace would change which ids the comma list
        # enables, and a key outside RESOURCE_KINDS names nothing.
        badIds = ["extensions." "extensions.a b" "extensions.ferment-v2,extensions.memory" "memory" "widgets.x"];
        withBad = failedAssertions (withKimchi {
          native.harnessSettings.resources = enabled // lib.genAttrs badIds (_: true);
        });
        hmResources =
          (hmHarnessSettings (evalHm {
            ai.kimchi = {
              enable = true;
              native.harnessSettings.resources = enabled // {"extensions.memory" = false;};
            };
          })).resources;
      in
        failedAssertions shadowed
        == []
        && projectHarnessSettings shadowed == {hideThinkingBlock = true;}
        && failedAssertions resourcesOnly == []
        && !(resourcesOnly.config.ai.files ? ".config/kimchi/harness/settings.json")
        && builtins.length withFalse == 1
        && lib.hasInfix "sets extensions.memory to false" (builtins.head withFalse)
        && builtins.length withBad == 1
        && lib.all (id: lib.hasInfix (builtins.toJSON id) (builtins.head withBad)) badIds
        && !(lib.any (id: lib.hasInfix (builtins.toJSON id) (builtins.head withBad)) (builtins.attrNames enabled))
        && hmResources == enabled // {"extensions.memory" = false;}
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
        (fileValue ".kimchi/config.json" result).redaction.enabled
        == false
        # Owner-only, so Kimchi's group/other read warning stays quiet.
        && files.".kimchi/config.json".mode == "0400"
        && result.config.ai.files.".kimchi/config.json".method == "ro"
        && (fileValue ".kimchi/mcp.json" result).mcpServers.example.command == "hello"
        && !(result.config.files ? ".kimchi/mcp.json")
        && files ? ".kimchi/skills/example/SKILL.md"
        && result.config.ai.filesOwners.".kimchi/skills/example" == ["kimchi"]
        && files ? "AGENTS.md"
        && !(files ? "custom.md")
        && !(lib.any (lib.hasPrefix "custom/kimchi") (builtins.attrNames files))
    );

    # Kimchi 1.1.37 reads lifecycle hooks from a trusted project's
    # .kimchi/hooks.json, in the Claude hook shape with timeouts in seconds
    # (src/extensions/kimchi-hooks/definition.ts:25-37,
    # src/extensions/hook-adapters/discovery.ts:130-190), and never writes it.
    # Its event set has no PermissionRequest, so that event is left out of the
    # file rather than written as bytes nothing reads. Home Manager has no
    # user-scope lifecycle file it can own: it writes nothing. Devenv warns for
    # the unsupported PermissionRequest event; Home Manager warns once for the
    # missing sink, naming the per-runtime pool when it is set.
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
        policy = import ../../../config/ai-delivery.nix {inherit lib;};
        hookWarning = mode: path: reason: "${lib.showOption path} is set but ${mode} does not deliver it to kimchi (reason: ${reason})";
        projectEventWarning =
          hookWarning "devenv" ["ai" "hooks" "PermissionRequest"]
          (lib.head policy.definitions.hooks.kimchi.devenv.additionalWriters).reason;
        hmHookWarning = path: hookWarning "hm" path policy.definitions.hooks.kimchi.hm.reason;
        hmHookPaths = lib.filter (lib.hasInfix "hooks") (builtins.attrNames hm.config.home.file);
      in
        devenv.config.files ? ".kimchi/hooks.json"
        && devenv.config.ai.files.".kimchi/hooks.json".method == "symlink"
        && devenv.config.ai.files.".kimchi/hooks.json".requires == ["${devenv.config.ai.kimchi._generatedTree}"]
        && fileValue ".kimchi/hooks.json" devenv
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
        && devenv.config.warnings == [projectEventWarning]
        && !(onlyPermissionRequest.config.files ? ".kimchi/hooks.json")
        && onlyPermissionRequest.config.warnings == [projectEventWarning]
        && !((evalDevenv {ai.kimchi.enable = true;}).config.files ? ".kimchi/hooks.json")
        && (evalDevenv {ai.kimchi.enable = true;}).config.warnings == []
        && hmHookPaths == []
        && hm.config.warnings == [(hmHookWarning ["ai" "kimchi" "hooks"])]
        && hmRootOnly.config.warnings == [(hmHookWarning ["ai" "hooks"])]
        && (evalHm {ai.kimchi.enable = true;}).config.warnings == []
    );

    # Kimchi 1.1.37 reads a hard-coded user permissions.json and a trusted
    # project's .kimchi/permissions.json and validates both with a `.strict()`
    # schema (src/extensions/permissions/config.ts:11-37). Both are read-only
    # copies: the HM path ignores configDir and is owned with nothing declared;
    # devenv claims the project file only for a declaration, because Kimchi
    # fills its scalar defaults for any project file that exists. The option
    # refuses any key or value the schema would reject.
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
        fileValue ".config/kimchi/harness/permissions.json" hm
        == permissions
        && !(hm.config.home.file ? ".config/kimchi/harness/permissions.json")
        && fileValue ".kimchi/permissions.json" devenv == permissions
        && !(devenv.config.files ? ".kimchi/permissions.json")
        && fileValue ".config/kimchi/harness/permissions.json" emptyHm == {}
        && !(emptyDevenv.config.ai.files ? ".kimchi/permissions.json")
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
    # ignores `--approve`. Home Manager owns it as a read-only copy of the
    # staged renderer, which follows configDir like harness settings;
    # devenv rejects the option by name rather than dropping it, and each arm
    # has a control that isolates the one input under test.
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
        target = hm.config.ai.files."custom/kimchi/harness/trust.json";
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
        target.method
        == "ro"
        && lib.hasInfix "project-trust.py" target.content.run
        && target.mode == null
        && !(hm.config.home.file ? "custom/kimchi/harness/trust.json")
        && hmFailures projectTrust == []
        && builtins.any (lib.hasInfix "must be absolute paths") (hmFailures {"srv/projects" = true;})
        && builtins.any (lib.hasInfix "ai.kimchi.projectTrust is user scope") (failedAssertions rejected)
        && failedAssertions accepted == []
        # Devenv declares no trust file of any kind, even when accepted.
        && !(lib.any (lib.hasSuffix "trust.json") (builtins.attrNames accepted.config.ai.files))
        && !(lib.any (lib.hasSuffix "trust.json") (builtins.attrNames accepted.config.files))
    );

    # Devenv's existing scope boundary is unchanged: every non-null native
    # defaultProjectTrust is rejected because a project cannot set user trust;
    # null is accepted, omitted from the project settings, and adds no file.
    module-kimchi-devenv-default-project-trust-contract = mkTest "kimchi-devenv-default-project-trust-contract" (
      let
        evaluate = value:
          evalDevenv {
            ai.kimchi = {
              enable = true;
              native.harnessSettings.defaultProjectTrust = value;
            };
          };
        rejected = value:
          builtins.any
          (message:
            lib.hasInfix "defaultProjectTrust" message
            && lib.hasInfix "Set these with Home Manager" message)
          (failedAssertions (evaluate value));
        accepted = evaluate null;
      in
        lib.all rejected ["always" "ask" "never"]
        && failedAssertions accepted == []
        && projectHarnessSettings accepted == {}
        && !(accepted.config.ai.files ? ".config/kimchi/harness/settings.json")
    );

    # Git tokens are secrets Kimchi reads only from the user config.json.
    # Home Manager renders them into the config.json copy when the writer
    # runs, from their files, after the secret provider; the plan names the
    # path, never a token. Devenv rejects the option by name, and they have no
    # option under native.settings, which would put them in the store.
    module-kimchi-git-tokens = mkTest "kimchi-git-tokens" (
      let
        hm = evalHm {
          ai.kimchi = {
            enable = true;
            gitTokens."github.com" = redact.file "/run/secrets/kimchi-github";
          };
        };
        target = hm.config.ai.files.".config/kimchi/config.json";
        rejected = evalDevenv {
          ai.kimchi = {
            enable = true;
            gitTokens."github.com" = redact.file "/run/secrets/kimchi-github";
          };
        };
      in
        target.method
        == "ro"
        && target.mode == "0400"
        && lib.hasInfix "redact-read" target.content.run
        && lib.hasInfix "file /run/secrets/kimchi-github" target.content.run
        && lib.hasInfix ''"github.com": env.kimchi_git_token_0'' target.content.run
        && builtins.any (lib.hasInfix "ai.kimchi.gitTokens is user scope") (failedAssertions rejected)
        && !(builtins.tryEval (builtins.deepSeq
          (evalHm {
            ai.kimchi = {
              enable = true;
              native.settings.gitTokens."github.com" = "in-the-store";
            };
          }).config.ai.kimchi.native.settings
          true)).success
    );

    # Agents use engine-owned read-only copies; native source bytes still
    # enter the formatted tree, and empty declarations retire owned copies.
    module-kimchi-agents = mkTest "kimchi-agents" (
      let
        hm = evalHm agentConfig;
        devenv = evalDevenv agentConfig;
        expected = {
          "native.md" = nativeAgent;
          "reviewer.md" = "---\ndescription: \"Reviews code\"\n---\n\nBODY\n";
        };
        delivers = evaluated: dir:
          builtins.attrNames (agentFiles dir evaluated)
          == map (name: "${dir}/${name}") (builtins.attrNames expected)
          && lib.all (name: let
            path = "${dir}/${name}";
            entry = evaluated.config.ai.files.${path};
          in
            entry.method
            == "ro"
            && entry.mode == null
            && entry.executable == null
            && fromGeneratedTree path (agentFiles dir evaluated).${path}
            && (markdownInput evaluated path).text == expected.${name})
          (lib.attrNames expected);
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
        deliveredAsSource = evaluated: dir:
          lib.all (name: let
            input = markdownInput evaluated "${dir}/${name}";
          in
            toString (input.source or "") == fixtureAgent && !(input ? text))
          ["agent-one.md" "store-string.md"];
        underAgents = prefix: lib.filter (lib.hasPrefix prefix);
      in
        delivers hm hmAgentsDir
        && delivers devenv devenvAgentsDir
        && failedAssertions hm == []
        && failedAssertions devenv == []
        && !(hm.config.home.activation ? kimchiAgents)
        && !(hm.config.home.activation ? kimchiAgentsPrune)
        && !(devenv.config.tasks ? "ai:kimchi:agents")
        && underAgents ".config/kimchi/harness/agents" (builtins.attrNames hm.config.home.file) == []
        && underAgents ".kimchi/agents" (builtins.attrNames devenv.config.files) == []
        && agentFiles hmAgentsDir emptyHm == {}
        && agentFiles devenvAgentsDir emptyDevenv == {}
        && (markdownInput fromDir "${devenvAgentsDir}/agent-one.md").source == ../../claude-code/checks/fixtures/claude-agents/agent-one.md
        && deliveredAsSource (evalHm stringConfig) hmAgentsDir
        && deliveredAsSource (evalDevenv stringConfig) devenvAgentsDir
    );

    # A normalized record's Claude/Copilot `tools` list has no Kimchi reading.
    # It is dropped from the rendered file and warns at the path that set it,
    # naming native Markdown as the remedy; withdrawing the agent, or an empty
    # list, stays silent.
    module-kimchi-agent-tools-warns = mkTest "kimchi-agent-tools-warns" (
      let
        evaluate = evaluator: agents: kimchiAgents:
          evaluator {
            ai = {
              inherit agents;
              kimchi = {
                enable = true;
                agents = kimchiAgents;
              };
            };
          };
        withTools = {
          description = "d";
          instructions.text = "BODY";
          tools = ["Read"];
        };
        warnsAt = path: evaluated:
          lib.any (message: lib.hasPrefix "${path} is set but" message && lib.hasInfix "native Kimchi Markdown" message) evaluated.config.warnings;
        quiet = evaluated: !(lib.any (lib.hasInfix ".tools is set but") evaluated.config.warnings);
      in
        lib.all ({
          evaluator,
          dir,
        }: let
          rootTools = evaluate evaluator {probe = withTools;} {};
        in
          warnsAt "ai.agents.probe.tools" rootTools
          && failedAssertions rootTools == []
          && !(lib.hasInfix "tools:" (markdownInput rootTools "${dir}/probe.md").text)
          && warnsAt "ai.kimchi.agents.probe.tools" (evaluate evaluator {} {probe = withTools;})
          && quiet (evaluate evaluator {probe = withTools;} {probe = null;})
          && quiet (evaluate evaluator {probe = withTools // {tools = [];};} {}))
        [
          {
            evaluator = evalHm;
            dir = hmAgentsDir;
          }
          {
            evaluator = evalDevenv;
            dir = devenvAgentsDir;
          }
        ]
    );

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
      # subdirectory and the wrapper must not refuse the launch. Region and
      # telemetry reach Kimchi through its environment, not a project file,
      # and so do harness resources.
      unguardedPackages = [
        (mkDevenvKimchiPackage {})
        (mkDevenvKimchiPackage {
          ai.kimchi.native.harnessSettings.resources."extensions.todos" = true;
        })
        (mkDevenvKimchiPackage {
          ai.kimchi.native.settings = {
            region = "eu";
            telemetry.enabled = false;
          };
        })
      ];
    in
      pkgs.runCommand "module-test-kimchi-devenv-exact-cwd-guard" {} ''
        for kimchi_bin in ${lib.concatMapStringsSep " " (package: "${package}/bin/kimchi") unguardedPackages}; do
          (cd ${exactCwdProjectRoot}/subdir && "$kimchi_bin")
        done

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

    # References must evaluate without becoming shell environment entries;
    # literals and the retired credential records fail on both backends.
    module-kimchi-credential = mkTest "kimchi-credential" (
      let
        result = evalDevenv {
          ai.kimchi = {
            enable = true;
            apiKey = redact.file "/run/secrets/kimchi-key";
          };
        };
      in
        builtins.length result.config.packages
        == 1
        # The cross-harness SSH default is exercised separately; this assertion
        # guards only against baking the Kimchi credential into the environment.
        && removeAttrs result.config.env ["GIT_SSH_COMMAND"] == {}
        && lib.all (evaluate:
          lib.all (value:
            (evaluate {ai.kimchi.apiKey = value;}).config.ai.kimchi.apiKey
            == value
            && (evaluate {ai.kimchi.gitTokens."github.com" = value;}).config.ai.kimchi.gitTokens."github.com" == value)
          [
            null
            (redact.file "/run/secrets/kimchi-key")
            (redact.command "/run/kimchi-key")
            (redact.concat ["prefix-" (redact.file "/run/secrets/kimchi-key")])
          ]
          && lib.all (value:
            !(builtins.tryEval (builtins.deepSeq (evaluate {ai.kimchi.apiKey = value;}).config.ai.kimchi.apiKey true)).success
            && !(builtins.tryEval (builtins.deepSeq (evaluate {ai.kimchi.gitTokens."github.com" = value;}).config.ai.kimchi.gitTokens true)).success)
          ["literal-secret" {file = "/run/secrets/kimchi-key";} {helper = "/run/kimchi-key";}])
        [evalHm evalDevenv]
    );

    # Real-execution gate for the wrapProgram blocker (#1) + secret handling
    # (#3): build the wrapped package (over the tiny aiStubs.kimchi bin) with
    # a second env var plus a credential, and assert the wrapper sets static
    # env via --set and resolves the key through the shared reader, never
    # baking the secret literal into the store. The old backslash-newline
    # separator made this build fail with exit 127 once >=2 args were present.
    # Home Manager supplies region and telemetry through global config.json,
    # and resources through the user harness settings.json. Devenv has no
    # global file and keeps exporting declared values. Its resource ids are
    # appended to KIMCHI_ENABLE_RESOURCES, so a caller's value and an
    # ai.kimchi environment value both survive; the env-printing stub proves
    # the merge by running the wrapper.
    module-kimchi-wrapper-builds = let
      result = evalHm {
        ai.kimchi = {
          enable = true;
          apiKey = redact.file "/run/secrets/kimchi-test";
          environmentVariables.KIMCHI_EXTRA = "yes";
          native.harnessSettings.resources."extensions.todos" = true;
        };
      };
      wrapped = builtins.head result.config.home.packages;
      devenvConfigured = mkDevenvKimchiPackage {
        ai.kimchi.native.settings = {
          region = "eu";
          telemetry.enabled = false;
        };
      };
      devenvDefault = mkDevenvKimchiPackage {};
      resourcesStub = pkgs.writeShellScriptBin "kimchi" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf '%s\n' "''${KIMCHI_ENABLE_RESOURCES-unset}"
      '';
      devenvResources = extraKimchi:
        mkDevenvKimchiPackage {
          ai.kimchi =
            {
              package = resourcesStub;
              native.harnessSettings.resources = {
                "extensions.ferment-v2" = true;
                "extensions.todos" = true;
              };
            }
            // extraKimchi;
        };
      devenvResourcesOnly = devenvResources {};
      devenvResourcesWithEnvironment = devenvResources {
        environmentVariables.KIMCHI_ENABLE_RESOURCES = "extensions.teleport";
      };
    in
      pkgs.runCommand "module-test-kimchi-wrapper-builds" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        bin=${wrapped}/bin/kimchi
        grep -q "KIMCHI_EXTRA" "$bin"
        grep -q 'redact-read ai.kimchi.apiKey file /run/secrets/kimchi-test' "$bin"
        # Failed reads must abort even without errexit in makeWrapper's shell.
        grep -q '|| exit 1' "$bin"
        grep -q "KIMCHI_REGION.*eu" ${devenvConfigured}/bin/kimchi
        grep -q "KIMCHI_TELEMETRY_ENABLED.*0" ${devenvConfigured}/bin/kimchi
        expect_resources() {
          local expected=$1 actual
          shift
          actual="$("$@")"
          if [ "$actual" != "$expected" ]; then
            echo "KIMCHI_ENABLE_RESOURCES: expected '$expected', got '$actual'" >&2
            exit 1
          fi
        }
        expect_resources extensions.ferment-v2,extensions.todos \
          env -u KIMCHI_ENABLE_RESOURCES ${devenvResourcesOnly}/bin/kimchi
        # Set but empty: no leading comma.
        expect_resources extensions.ferment-v2,extensions.todos \
          env KIMCHI_ENABLE_RESOURCES= ${devenvResourcesOnly}/bin/kimchi
        expect_resources extensions.memory,extensions.ferment-v2,extensions.todos \
          env KIMCHI_ENABLE_RESOURCES=extensions.memory ${devenvResourcesOnly}/bin/kimchi
        expect_resources extensions.teleport,extensions.ferment-v2,extensions.todos \
          env -u KIMCHI_ENABLE_RESOURCES ${devenvResourcesWithEnvironment}/bin/kimchi
        # `! grep` never fails under errexit, so each absence is an explicit branch.
        if grep -qE "KIMCHI_(ENABLE_RESOURCES|REGION|TELEMETRY_ENABLED)" "$bin"; then
          echo "Home Manager duplicated config.json settings in the launcher" >&2
          exit 1
        fi
        if grep -qE "KIMCHI_(ENABLE_RESOURCES|REGION|TELEMETRY_ENABLED)" ${devenvDefault}/bin/kimchi; then
          echo "devenv set a global-only setting nobody declared" >&2
          exit 1
        fi
        echo PASS > "$out"
      '';
  };
}
