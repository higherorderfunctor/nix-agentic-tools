# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  extractedLib,
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv fromGeneratedTree markdownInput mkTest ownPlan ownedDocument;
  evalHm = config: harness.evalHm (lib.mkMerge [{ai.kimchi.native.settings.region = lib.mkOverride 1200 "us";} config]);
  workflows = pkgs.ai.kimchiExtensions.kimchi-workflows;
  workflowsHarness = ".config/kimchi/harness";
  # Reuse these module evaluations for the structural check and runtime smoke.
  workflowsBackends = map (backend:
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
  # The units one writer owns in one directory, read from the plan it applies.
  dirTarget = entry: dir: evaluated:
    lib.head (lib.filter (target: target.codec == "dir" && target.path == dir)
      (ownPlan "kimchi" entry evaluated).targets);
  dirUnits = entry: dir: evaluated: (dirTarget entry dir evaluated).units;
  hmFiles = dirUnits "kimchiFiles";
  devenvFiles = dirUnits "ai:kimchi:files";
  # A settings copy's declared JSON, before its generated tree renders bytes.
  fileValue = path: evaluated: evaluated.config.ai.kimchi.files.${path}.content.value;
  hmHarnessSettings = evaluated:
    (ownedDocument "kimchi" "${evaluated.config.ai.kimchi.configDir}/harness/settings.json" evaluated).value;
  projectFiles = devenvFiles ".kimchi";
  # devenv claims the copy only when something is declared, so an undeclared
  # harness settings.json is absent from the directory's units entirely.
  projectHarnessSettings = evaluated: let
    units = devenvFiles ".config/kimchi/harness" evaluated;
  in
    if units ? "settings.json"
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
  # The keys come from the sidecar; each needs a sample value here, so a key
  # that becomes user-scope fails evaluation until someone adds one.
  userScopeOnlyHarnessSettingKeys =
    (import ../lib/extracted.nix {
      inherit extractedLib lib pkgs;
      extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
    }).userScopeHarnessKeys;
  userScopeOnlyHarnessSettingValues = {
    defaultProjectTrust = "always";
    fermentV2.autoResume = true;
    hidePhaseChanges = true;
    httpProxy = "http://proxy.invalid:3128";
    lastTerminalWarnings.kitty = "0.35.0";
    modelMetadata.example.description = "Example model";
    modelRoles.builder = "provider/model";
    multiModel = true;
    shellProfileApiKeyMigrationDismissed = true;
    statusLine.pinned = ["model"];
  };
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
  hmAgentUnits = dirUnits "kimchiAgents" hmAgentsDir;
  devenvAgentUnits = dirUnits "ai:kimchi:agents" devenvAgentsDir;
  failedAssertions = evaluated: map (entry: entry.message) (builtins.filter (entry: !entry.assertion) evaluated.config.assertions);
  # The Home Manager settings-copies writer as a runnable script: its prune
  # entry and then its write entry, with home-manager's `run` helper in scope.
  hmFilesWriter = config: let
    inherit ((evalHm config).config.home) activation;
  in
    pkgs.writeShellScript "kimchi-files-hm" ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${harness.hmRunShim}
      ${activation.kimchiFilesPrune.text}
      ${activation.kimchiFiles.text}
    '';

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
          }).config.home.activation.kimchiFiles
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
    module-kimchi-project-trust-notice = let
      linesOf = evaluated: lib.filter (lib.hasInfix "/bin/kimchi-project-trust-notice ") (lib.splitString "\n" evaluated.config.enterShell);
      configured = settings:
        evalDevenv {
          ai.kimchi = {
            enable = true;
            native = settings;
          };
        };
      config = configured {settings.redaction.enabled = false;};
      harnessConfig = configured {harnessSettings.defaultThinkingLevel = "high";};
      suppressed = evalDevenv {
        ai.kimchi = {
          enable = true;
          native.settings.redaction.enabled = false;
          files.".kimchi/config.json".content.enable = false;
        };
      };
      rendered = evaluated:
        pkgs.writeShellScript "rendered-kimchi-project-trust-notice" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${lib.head (linesOf evaluated)}
        '';
    in
      assert builtins.length (linesOf config) == 1 && builtins.length (linesOf harnessConfig) == 1;
      assert linesOf (evalDevenv {}) == [] && linesOf (configured {}) == [] && linesOf suppressed == [];
      assert linesOf (evalDevenv {
        ai.kimchi = {
          context.text = "CONTEXT";
          enable = true;
        };
      })
      == [];
        pkgs.runCommand "module-test-kimchi-project-trust-notice" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${pkgs.python3}/bin/python3 ${./project-trust-notice-test.py} ${rendered config} ${rendered harnessConfig}
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
              (lib.head (lib.filter (target: target.path == settingsPath)
                  (ownPlan "kimchi" "kimchiFiles" backend.one).targets)).units.text
            else files.${settingsPath}.source;
        in {
          inherit (backend) name;
          inherit settings;
          extension = files."${workflowsHarness}/extensions/workflows".source;
        })
        workflowsBackends;
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
            lib.filterAttrs (path: _: lib.hasPrefix "${workflowsHarness}/extensions/" path) (deliveredFiles evaluated.config);
          checkLinks = evaluated: names:
            builtins.attrNames (extensionFiles evaluated)
            == map (name: "${workflowsHarness}/extensions/${name}") names
            && lib.all (name: let
              path = "${workflowsHarness}/extensions/${name}";
              file = (extensionFiles evaluated).${path};
            in
              fromGeneratedTree path file
              && builtins.hasContext file.source
              && !(file.recursive or false))
            names;
          rejected = builtins.tryEval (builtins.deepSeq (withExtensions {workflows = "${workflows}";}).config.ai.kimchi.extensions true);
        in
          lib.all (evaluated: lib.all (assertion: assertion.assertion) evaluated.config.assertions) [empty one two]
          && extensionFiles empty == {}
          && !((settings empty) ? packages)
          && checkLinks one ["workflows"]
          && checkLinks two ["another" "workflows"]
          && (settings one).packages == ["extensions/workflows"]
          && lib.sort builtins.lessThan (settings two).packages == ["/consumer/package" "extensions/another" "extensions/workflows"]
          && !rejected.success;
      in
        lib.all checkBackend workflowsBackends
    );

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
        result.config.home.activation ? kimchiFiles
        && (hmConfigDocument result).value.telemetry.enabled == false
    );

    # Home Manager owns declared leaves in config.json and settings.json, and
    # keeps the other harness files as read-only copies. Devenv, with nothing
    # declared, keeps its writer and both directory ledgers and claims no file.
    module-kimchi-hm-owns-user-files = mkTest "kimchi-hm-owns-user-files" (
      let
        evaluated = evalHm {ai.kimchi.enable = true;};
        activation = evaluated.config.home.activation;
        units = hmFiles ".config/kimchi/harness" evaluated;
        devenv = evalDevenv {ai.kimchi.enable = true;};
        devenvTargets = (ownPlan "kimchi" "ai:kimchi:files" devenv).targets;
      in
        lib.hasInfix "--phase all" activation.kimchiFiles.text
        && lib.hasInfix "--phase prune" activation.kimchiFilesPrune.text
        && lib.hasPrefix "materialize/kimchi-shared-" (hmConfigDocument evaluated).ledger
        && (hmConfigDocument evaluated).value == userConfigDefaults
        && evaluated.config.ai.kimchi.files.".config/kimchi/config.json".facts.harnessWrites
        && evaluated.config.ai.kimchi.files.".config/kimchi/config.json".mode == null
        && evaluated.config.ai.kimchi.files.".config/kimchi/harness/settings.json".facts.harnessWrites
        && evaluated.config.ai.kimchi.files.".config/kimchi/harness/settings.json".mode == null
        && builtins.attrNames units == ["mcp.json" "permissions.json" "trust.json"]
        && hmHarnessSettings evaluated == userHarnessDefaults
        && fileValue ".config/kimchi/harness/mcp.json" evaluated == {}
        && fileValue ".config/kimchi/harness/permissions.json" evaluated == {}
        # Every remaining copy takes the reconciler's read-only default mode.
        && lib.all (unit: !(unit ? mode)) (builtins.attrValues units)
        && !(lib.any (lib.hasPrefix ".config/kimchi/harness/") (builtins.attrNames evaluated.config.home.file))
        && devenv.config.tasks ? "ai:kimchi:files"
        && builtins.sort builtins.lessThan (map (target: target.path) devenvTargets) == [".config/kimchi/harness" ".kimchi"]
        && lib.all (target: target.units == {}) devenvTargets
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

    # Upgrade contract: generations before project-path delivery keyed the HM
    # config ledger by configDir. Shared documents key their ledgers by path;
    # read-only copies retain one directory ledger per directory.
    module-kimchi-hm-ledger-identity = mkTest "kimchi-hm-ledger-identity" (
      let
        configDir = "custom/kimchi";
        evaluated = evalHm {
          ai.kimchi = {
            inherit configDir;
            enable = true;
          };
        };
        ledgerOf = dir: (dirTarget "kimchiFiles" dir evaluated).ledger;
      in
        (hmConfigDocument evaluated).ledger
        == "materialize/kimchi-shared-${builtins.hashString "sha256" "${configDir}/config.json"}.json"
        && (ownedDocument "kimchi" "${configDir}/harness/settings.json" evaluated).ledger
        == "materialize/kimchi-shared-${builtins.hashString "sha256" "${configDir}/harness/settings.json"}.json"
        && builtins.attrNames (hmFiles "custom/kimchi/harness" evaluated) == ["mcp.json" "trust.json"]
        && builtins.attrNames (hmFiles ".config/kimchi/harness" evaluated) == ["permissions.json"]
        && ledgerOf "custom/kimchi/harness" == "materialize/kimchi-files-${builtins.hashString "sha256" "custom/kimchi/harness"}.manifest"
        && ledgerOf ".config/kimchi/harness" == "materialize/kimchi-files-${builtins.hashString "sha256" ".config/kimchi/harness"}.manifest"
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
        result.config.tasks
        ? "ai:kimchi:files"
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
        && !((projectFiles emptyDevenv) ? "mcp.json")
    );

    # Kimchi 1.1.37 accepts a role value only as a provider/model string, or
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
        !((withPaths {}).config.ai.kimchi.files ? ".kimchi/config.json")
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
        && !((projectFiles shadowed) ? "config.json")
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
        && !((devenvFiles ".config/kimchi/harness" resourcesOnly) ? "settings.json")
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
        && result.config.tasks ? "ai:kimchi:files"
        && (fileValue ".kimchi/mcp.json" result).mcpServers.example.command == "hello"
        && !(result.config.files ? ".kimchi/mcp.json")
        && files ? ".kimchi/skills/example/SKILL.md"
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
        fromGeneratedTree ".kimchi/hooks.json" devenv.config.files.".kimchi/hooks.json"
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
        && !((projectFiles emptyDevenv) ? "permissions.json")
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
    # `kimchiFiles` writer, which follows configDir like harness settings;
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
        target = dirTarget "kimchiFiles" "custom/kimchi/harness" hm;
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
        lib.hasPrefix "materialize/kimchi-files-" target.ledger
        && lib.hasInfix "project-trust.py" target.units."trust.json".run
        && !(target.units."trust.json" ? mode)
        && !(hm.config.home.file ? "custom/kimchi/harness/trust.json")
        && hmFailures projectTrust == []
        && builtins.any (lib.hasInfix "must be absolute paths") (hmFailures {"srv/projects" = true;})
        && builtins.any (lib.hasInfix "ai.kimchi.projectTrust is user scope") (failedAssertions rejected)
        && failedAssertions accepted == []
        # Devenv declares no trust file of any kind, even when accepted.
        && !(lib.any (target: lib.any (lib.hasSuffix "trust.json") ([target.path] ++ builtins.attrNames target.units))
          (lib.concatMap (record: record.plan.targets) (lib.attrValues accepted.config.ai.kimchi._ownPlans)))
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
        && !(projectFiles accepted ? "settings.json")
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
            gitTokens."github.com".file = "/run/secrets/kimchi-github";
          };
        };
        target = dirTarget "kimchiFiles" hm.config.ai.kimchi.configDir hm;
        rejected = evalDevenv {
          ai.kimchi = {
            enable = true;
            gitTokens."github.com".file = "/run/secrets/kimchi-github";
          };
        };
      in
        target.path
        == ".config/kimchi"
        && hm.config.ai.kimchi.files.".config/kimchi/config.json".method == "copy-ro"
        && hm.config.ai.kimchi.files.".config/kimchi/config.json".mode == "0400"
        && lib.hasInfix ''cat "/run/secrets/kimchi-github"'' target.units."config.json".run
        && lib.hasInfix ''"github.com": env.kimchi_git_token_0'' target.units."config.json".run
        && lib.elem "sops-nix" hm.config.home.activation.kimchiFiles.after
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

    # Runs the real Home Manager writer. A key reached through a symlink must
    # land under its realpath, the only key pi 0.85.1 ever looks up
    # (findNearestTrustEntry); a missing tail is still declared; and two keys
    # resolving to one directory with different answers fail the writer
    # without touching the file.
    module-kimchi-project-trust-runtime = let
      fixture = pkgs.runCommand "kimchi-project-trust-fixture" {} ''
        mkdir -p "$out/real/project"
        ln -s real "$out/link"
      '';
      # An attribute name cannot carry string context. The runCommand below
      # interpolates `fixture` itself, which keeps it in the check's closure.
      under = relative: builtins.unsafeDiscardStringContext "${fixture}/${relative}";
      writer = projectTrust:
        hmFilesWriter {
          ai.kimchi = {
            enable = true;
            inherit projectTrust;
          };
        };
      declared = writer {
        ${under "link/project"} = true;
        "/nonexistent/kimchi-project" = false;
      };
      conflicting = writer {
        ${under "link/project"} = true;
        ${under "real/project"} = false;
      };
    in
      pkgs.runCommand "module-test-kimchi-project-trust-runtime" {nativeBuildInputs = [pkgs.jq];} ''
        fail() { echo "FAIL: kimchi-project-trust-runtime: $1" >&2; exit 1; }
        export HOME="$TMPDIR/home"
        export XDG_STATE_HOME="$TMPDIR/state"
        trust="$HOME/.config/kimchi/harness/trust.json"

        ${declared}
        jq -e --arg real '${fixture}/real/project' '.[$real] == true' "$trust" >/dev/null \
          || fail "the symlinked key did not land under its realpath: $(cat "$trust")"
        jq -e --arg link '${fixture}/link/project' 'has($link) | not' "$trust" >/dev/null \
          || fail "the literal symlinked key was written, which Kimchi never matches"
        jq -e '.["/nonexistent/kimchi-project"] == false' "$trust" >/dev/null \
          || fail 'a declared path that does not exist yet was dropped'

        cp "$trust" "$TMPDIR/before-conflict"
        if ${conflicting} 2>"$TMPDIR/conflict.err"; then
          fail 'two keys resolving to one directory with different decisions were accepted'
        fi
        grep -q 'declare different decisions' "$TMPDIR/conflict.err" \
          || fail "the conflict did not name its cause: $(cat "$TMPDIR/conflict.err")"
        cmp "$TMPDIR/before-conflict" "$trust" || fail 'a failed render changed trust.json'
        echo PASS > "$out"
      '';

    # The settings writers, executed against a scratch HOME. A file an earlier generation reconciled
    # (a declared server plus one Kimchi migrated in) is adopted: backed up
    # once and replaced by the declaration, 0444. A later in-app edit renames a
    # new file over the copy, as Kimchi's writers do; the next run backs it up
    # and restores the declaration. trust.json holds the declared decisions
    # only. Runtime-owned leaves survive in the two shared Home Manager
    # documents, while declared leaves return to their Nix values. Devenv's
    # project config.json remains owner-only.
    module-kimchi-files-runtime = let
      server = {
        package = pkgs.hello;
        command = "hello";
        type = "stdio";
      };
      hmConfig = {
        ai = {
          mcpServers.declared = server;
          kimchi = {
            enable = true;
            projectTrust."/srv/projects" = true;
          };
        };
      };
      hm = hmFilesWriter hmConfig;
      hmEvaluated = evalHm hmConfig;
      declaredMcp = (hmFiles ".config/kimchi/harness" hmEvaluated)."mcp.json".store;
      devenv = pkgs.writeShellScript "kimchi-files-devenv" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${(evalDevenv {
          ai.mcpServers.declared = server;
          ai.kimchi = {
            enable = true;
            native.harnessSettings.hideThinkingBlock = true;
            native.settings.redaction.enabled = false;
            permissions.defaultMode = "plan";
          };
        }).config.tasks."ai:kimchi:files".exec}
      '';
    in
      pkgs.runCommand "module-test-kimchi-files-runtime" {nativeBuildInputs = [pkgs.jq];} ''
        fail() { echo "FAIL: kimchi-files-runtime: $1" >&2; exit 1; }
        export HOME="$TMPDIR/home"
        export XDG_STATE_HOME="$TMPDIR/state"
        harness="$HOME/.config/kimchi/harness"
        mcp="$harness/mcp.json"
        backups() { ls "$XDG_STATE_HOME"/nix-agentic-tools/materialize/kimchi-files-*.bak/mcp.json.* 2>/dev/null | wc -l; }
        mkdir -p "$harness"
        jq '.mcpServers.migrated = {"command": "migrated"}' ${declaredMcp} > "$mcp"

        ${hm}
        cmp ${declaredMcp} "$mcp" || fail "adoption did not restore the declaration: $(cat "$mcp")"
        [ -f "$mcp" ] && [ ! -L "$mcp" ] || fail 'mcp.json is not a real file'
        [ "$(stat -c %a "$mcp")" = 444 ] || fail 'mcp.json is not read-only'
        [ "$(backups)" = 1 ] || fail 'the adopted file was not backed up once'
        trust="$harness/trust.json"
        [ -f "$trust" ] && [ "$(stat -c %a "$trust")" = 444 ] || fail 'trust.json is not a read-only file'
        jq -e '. == {"/srv/projects": true}' "$trust" >/dev/null \
          || fail "trust.json holds more than the declared decisions: $(cat "$trust")"

        # Kimchi's rename over the copy.
        printf '{"mcpServers":{}}\n' > "$TMPDIR/edited"
        mv -f "$TMPDIR/edited" "$mcp"
        ${hm}
        cmp ${declaredMcp} "$mcp" || fail 'the in-app edit was not replaced'
        [ "$(backups)" = 2 ] || fail 'the in-app edit was not backed up'

        config="$HOME/.config/kimchi/config.json"
        settings="$harness/settings.json"
        [ "$(stat -c %a "$config")" = 600 ] || fail 'new config.json is not owner-only'
        [ "$(stat -c %a "$settings")" = 600 ] || fail 'new settings.json is not owner-only'
        jq '.deviceId = "device" | .region = "eu"' "$config" > "$TMPDIR/native-config.json"
        chmod 600 "$TMPDIR/native-config.json"
        mv -f "$TMPDIR/native-config.json" "$config"
        jq '.lastChangelogVersion = "runtime" | .theme = "dark"' "$settings" > "$TMPDIR/native-settings.json"
        chmod 600 "$TMPDIR/native-settings.json"
        mv -f "$TMPDIR/native-settings.json" "$settings"
        ${hm}
        jq -e '.deviceId == "device" and .region == "us"' "$config" >/dev/null \
          || fail "config.json did not preserve runtime leaves and restore declared leaves: $(cat "$config")"
        jq -e '.lastChangelogVersion == "runtime" and .theme == "kimchi-minimal"' "$settings" >/dev/null \
          || fail "settings.json did not preserve runtime leaves and restore declared leaves: $(cat "$settings")"
        for path in "$harness/mcp.json" "$harness/permissions.json" "$harness/trust.json"; do
          if printf 'edit\n' > "$path" 2>/dev/null; then
            fail "in-place write succeeded against $path"
          fi
        done

        export DEVENV_ROOT="$TMPDIR/project"
        export DEVENV_STATE="$TMPDIR/project-state"
        mkdir -p "$DEVENV_ROOT"
        ${devenv}
        [ "$(stat -c %a "$DEVENV_ROOT/.kimchi/config.json")" = 400 ] || fail 'the project config.json is not owner-only'
        if printf 'edit\n' > "$DEVENV_ROOT/.kimchi/config.json" 2>/dev/null; then fail 'project config.json accepted an in-place write'; fi
        for path in "$DEVENV_ROOT/.kimchi/mcp.json" "$DEVENV_ROOT/.kimchi/permissions.json" "$DEVENV_ROOT/.config/kimchi/harness/settings.json"; do
          [ -e "$path" ] || fail "missing declared read-only copy $path"
          if printf 'edit\n' > "$path" 2>/dev/null; then fail "in-place write succeeded against $path"; fi
        done
        jq -e '. == {"redaction": {"enabled": false}}' "$DEVENV_ROOT/.kimchi/config.json" >/dev/null \
          || fail "the project config.json: $(cat "$DEVENV_ROOT/.kimchi/config.json")"
        echo PASS > "$out"
      '';

    # Kimchi reads `<agentDir>/agents/*.md` and a trusted project's
    # `.kimchi/agents/*.md`. Each agent is a read-only copy in a real
    # directory, never a store symlink: no home.file or devenv files entry, a
    # dir ledger, the reconciler's default mode. A portable record renders
    # without `name:` (the filename is the name); native
    # Markdown is not translated, so it is the Markdown tree's input as
    # written, and the tree's formatter and check then process it. An empty
    # declaration still emits the writer, so removing the last agent
    # retracts it.
    module-kimchi-agents = mkTest "kimchi-agents" (
      let
        hm = evalHm agentConfig;
        devenv = evalDevenv agentConfig;
        expected = {
          "native.md" = nativeAgent;
          "reviewer.md" = "---\ndescription: \"Reviews code\"\n---\n\nBODY\n";
        };
        # Each agent is a writable copy of its file in the Markdown tree.
        delivers = evaluated: dir: units:
          lib.attrNames units
          == lib.attrNames expected
          && lib.all (name:
            !(units.${name} ? mode)
            && fromGeneratedTree "${dir}/${name}" {source = units.${name}.store;}
            && (markdownInput evaluated "${dir}/${name}").text == expected.${name})
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
        delivers hm hmAgentsDir (hmAgentUnits hm)
        && delivers devenv devenvAgentsDir (devenvAgentUnits devenv)
        && failedAssertions hm == []
        && failedAssertions devenv == []
        && hm.config.home.activation ? kimchiAgents
        && hm.config.home.activation ? kimchiAgentsPrune
        && devenv.config.tasks ? "ai:kimchi:agents"
        && underAgents ".config/kimchi/harness/agents" (builtins.attrNames hm.config.home.file) == []
        && underAgents ".kimchi/agents" (builtins.attrNames devenv.config.files) == []
        && hmAgentUnits emptyHm == {}
        && devenvAgentUnits emptyDevenv == {}
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

    # The delivery itself, executed: the real HM prune and write entries and
    # the real devenv task, against scratch roots. The agent lands as a
    # read-only real file; a file renamed over it is backed up and replaced by
    # the declaration on the next run, a file Kimchi created beside it
    # survives, and an empty declaration removes only the owned file.
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
        expected = pkgs.writeText "kimchi-reviewer.md" (markdownInput (evalHm agentConfig) "${hmAgentsDir}/reviewer.md").text;
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
        [ "$(stat -c %a "$agent")" = 444 ] || fail '${backend}: agent is not read-only'
        if printf 'edit\n' > "$agent" 2>/dev/null; then fail '${backend}: agent accepted an in-place write'; fi
        cmp ${expected} "$agent" || fail '${backend}: agent content'

        # A replacement renamed over the copy, and a Create beside it.
        printf -- '---\nenabled: false\n' > "$TMPDIR/replacement.md"
        mv -f "$TMPDIR/replacement.md" "$agent"
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
          apiKey.file = "/run/secrets/kimchi-test";
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
        grep -q 'cat "/run/secrets/kimchi-test"' "$bin"
        # An empty credential file must abort the wrapper rather than let the
        # program start with the variable unset. Asserted on a REAL MCP
        # wrapper, not only glab's, because the guard lives in the shared
        # lib/credentials.nix and every server inherits it.
        grep -q 'KIMCHI_API_KEY resolved empty' "$bin"
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
