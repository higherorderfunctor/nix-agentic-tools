# Factory contracts for this owner or shared primitive.
# cspell:ignore agnets maxbytes
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai devenvStubs factoryProxyServer hmStubs mkProxyTestRecord mkTest;
  inherit (import ../../lib/testing/normalized-settings-probes.nix {inherit lib;}) requestFields resolvedSettingSample settingSample settingsFields;
  sharedRequests = {
    agents.probe = {
      description = "probe";
      instructions.text = "probe";
    };
    context.text = "probe";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    jail.enable = true;
    # A wholly unsupported MCP surface gets one surface diagnostic, even
    # when its transport would also drop fields on a capable runtime.
    mcpServers.probe = {
      command = "probe";
      headers.Authorization = "probe";
    };
    proxy.http = "http://proxy.invalid:8080";
    rules.probe.text = "probe";
    settings = lib.genAttrs settingsFields settingSample;
    shell = pkgs.bash;
    skills.probe = ../../packages/claude-code/checks/fixtures/claude-skills/skill-a;
  };
  backends = ["devenv" "hm"];
  build = ai.app.mkRuntime;
  builtName = input: (build input).name;
  rejectsRecord = valid: invalid:
    rejectsChange builtName {
      inherit invalid valid;
      expected = "testapp";
    };
  evaluateWith = {
    extraModules ? [],
    specialArgs ? {},
  }: backend: records: config:
    lib.evalModules {
      inherit specialArgs;
      modules =
        [
          ai.sharedOptions
          (
            if backend == "hm"
            then hmStubs
            else devenvStubs
          )
        ]
        ++ extraModules
        ++ map ai.app.${backend + "Transform"} records
        ++ [{inherit config;}];
    };
  evaluate = evaluateWith {};
  evaluateProxy = evaluateWith {specialArgs = {inherit pkgs;};};
  evaluateWarnings = evaluateWith {
    extraModules = [
      {
        options.warnings = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
        };
      }
    ];
  };
  evaluateSupport = backend: record: requests: enabled:
    evaluateWarnings backend [record] {
      ai = lib.recursiveUpdate requests (lib.setAttrByPath [record.name "enable"] enabled);
    };
  proxyRuntime = key: port: {
    enable = true;
    mcpServers.${key} = factoryProxyServer port;
  };
  directProxy = backend: port:
    (evaluateProxy backend [(mkProxyTestRecord "testapp")] {ai.testapp = proxyRuntime "direct" port;}).config;
  runtimeEnabled = backend: record: config: (evaluate backend [record] config).config.ai.testapp.enable;
  decomposeCase = backend: surfaceSupport: supportsSkills: let
    record = build {
      inherit pkgs surfaceSupport;
      name = "testapp";
      # A same-named native option does not elect to handle shared hooks.
      options.hooks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
    };
    evaluate = evaluateSupport backend record;
    evaluated = evaluate sharedRequests true;
    warnings = evaluated.config.warnings;
    expectedPaths =
      lib.concatMap
      (surface: map (field: surface + lib.optionalString (field != null) ".${field}") (requestFields surface))
      (builtins.attrNames (removeAttrs sharedRequests (lib.optional supportsSkills "skills")));
  in
    checkRows "${backend} shared surface diagnostics" {
      "a disabled runtime emits no warnings" = (evaluate sharedRequests false).config.warnings == [];
      "an empty request emits no warnings" = (evaluate {} true).config.warnings == [];
      # Every registered surface is exercised, and each unsupported surface
      # gets exactly one diagnostic through the public factory on both backends.
      "every registered surface has a probe" = builtins.attrNames sharedRequests == evaluated.config.ai.internal.sharedSurfaces;
      "supported skills are delivered" = !supportsSkills || evaluated.config.ai.testapp.normalized.skills == sharedRequests.skills;
      "unsupported surfaces emit exactly one warning per expected path" =
        builtins.length warnings
        == builtins.length expectedPaths
        && lib.all (path:
          builtins.length (lib.filter
            (lib.hasPrefix "ai.${path} is set but ${backend} does not deliver it to testapp (reason: ")
            warnings)
          == 1)
        expectedPaths;
    };
in {
  checks = {
    factory-mkRuntime-decompose-no-surfaces = mkTest "mkRuntime-decompose-no-surfaces" (
      checkRows "unsupported surface declarations" (lib.genAttrs backends (backend:
        checkRows backend {
          "an empty backend list does not consume skills" = decomposeCase backend {skills.backends = [];} false;
          "an omitted declaration does not consume skills" = decomposeCase backend {} false;
        }))
    );
    factory-mkRuntime-decompose-one-surface = mkTest "mkRuntime-decompose-one-surface" (
      checkRows "declared skills support" (lib.genAttrs backends (backend:
          decomposeCase backend {skills.backends = backends;} true))
    );
    factory-mkRuntime-declared-backend-support = mkTest "mkRuntime-declared-backend-support" (
      let
        reason = "Only Home Manager delivers this surface.";
        record = build {
          inherit pkgs;
          name = "testapp";
          surfaceSupport.agents = {
            backends = ["hm"];
            inherit reason;
          };
        };
        request = {inherit (sharedRequests) agents;};
        warning = backend: path: "${path} is set but ${backend} does not deliver it to testapp (reason: ${reason})";
      in
        checkRows "declared backend support" (lib.genAttrs backends (backend: let
          evaluate = requests: enabled: (evaluateSupport backend record requests enabled).config;
          expected = path: lib.optional (backend == "devenv") (warning backend path);
        in
          checkRows backend {
            "disabled runtime does not warn" = (evaluate request false).warnings == [];
            "empty request does not warn" = (evaluate {} true).warnings == [];
            "local null suppresses inherited request" = (evaluate (request // {testapp.agents.probe = null;}) true).warnings == [];
            "normalized agent remains available on both backends" = (evaluate request true).ai.testapp.normalized.agents.probe.description == "probe";
            "root request identifies root input on the unsupported backend" = (evaluate request true).warnings == expected "ai.agents";
            "runtime request identifies runtime input on the unsupported backend" = (evaluate {testapp.agents = request.agents;} true).warnings == expected "ai.testapp.agents";
          }))
    );
    factory-mkRuntime-declared-nested-gap = mkTest "mkRuntime-declared-nested-gap" (
      let
        reason = "This runtime has no portable tool allowlist.";
        record = build {
          inherit pkgs;
          name = "testapp";
          surfaceSupport.agents.gaps = [
            {
              each = true;
              path = ["tools"];
              inherit reason;
            }
          ];
        };
        request.agents.probe = sharedRequests.agents.probe // {tools = ["Read"];};
      in
        checkRows "declared nested gap" (lib.genAttrs backends (backend: let
          warnings = requests: enabled: (evaluateSupport backend record requests enabled).config.warnings;
          expected = path: ["${path}.tools is set but ${backend} does not deliver it to testapp (reason: ${reason})"];
        in
          checkRows backend {
            "disabled runtime does not warn" = warnings request false == [];
            "empty request does not warn" = warnings {} true == [];
            "empty tools list does not warn" = warnings {agents.probe = sharedRequests.agents.probe // {tools = [];};} true == [];
            "local agent without tools replaces inherited request" = warnings (request // {testapp.agents.probe = sharedRequests.agents.probe;}) true == [];
            "local null suppresses inherited request" = warnings (request // {testapp.agents.probe = null;}) true == [];
            "root agent warning identifies root tools" = warnings request true == expected "ai.agents.probe";
            "runtime agent warning identifies runtime tools" = warnings {testapp.agents = request.agents;} true == expected "ai.testapp.agents.probe";
          }))
    );
    factory-mkRuntime-declared-static-gap = mkTest "mkRuntime-declared-static-gap" (
      # Kimchi's only static gap, PermissionRequest, is not a native hook option.
      # A fixture exposes a dropped field in a pool with root copy-down instead.
      let
        record = build {
          inherit pkgs;
          name = "testapp";
          surfaceSupport.settings = {
            fields = ["inference" "reasoningEffort"];
            gaps = [
              {
                path = ["inference" "url"];
                reason = "testapp drops the inference URL.";
              }
            ];
          };
        };
        rootRequest.settings.inference = settingSample "inference";
      in
        checkRows "declared static gap" (lib.genAttrs backends (backend: let
          warnings = enabled: requests: (evaluateSupport backend record requests enabled).config.warnings;
          expected = path: ["ai.${path}.url is set but ${backend} does not deliver it to testapp (reason: testapp drops the inference URL.)"];
        in
          checkRows backend {
            "disabled runtime does not warn" = warnings false rootRequest == [];
            "empty request does not warn" = warnings true {} == [];
            "normalized input warns at the normalized path" = warnings true {testapp.normalized.settings.inference = resolvedSettingSample "inference";} == expected "testapp.normalized.settings.inference";
            "root copy-down warns once at the runtime pool path" = warnings true rootRequest == expected "testapp.settings.inference";
            "runtime input warns at the runtime pool path" = warnings true {testapp.settings.inference = settingSample "inference";} == expected "testapp.settings.inference";
            "unrelated settings field does not warn" = warnings true {testapp.settings.reasoningEffort = "high";} == [];
          }))
    );
    # ── mkRuntime tests ───────────────────────────────────────────────
    # The per-backend seam is retired: delivery is ONE record-level `config`,
    # and a backend spec takes only installPackage, migrationConfig and
    # options. A record still written against the seam must fail loudly
    # rather than evaluate to a runtime that delivers nothing, both where the
    # record is built and where a transform reads it: the exported records are
    # plain attrsets, so an override (`r // {hm = …;}`) or a hand-built record
    # reaches `hmTransform` / `devenvTransform` without passing `mkRuntime`.
    # The record-level `config`, a callback `installPackage` and the untouched
    # record are the positive controls.
    factory-mkRuntime-rejects-backend-seam = mkTest "mkRuntime-rejects-backend-seam" (
      let
        base = {
          inherit pkgs;
          name = "testapp";
          defaults.package = pkgs.hello;
        };
        built = build base;
        constructorRejects = rejectsRecord base;
        backendRows = backend: let
          transformRejects = invalid:
            rejectsChange (record: runtimeEnabled backend record {ai.testapp.enable = true;}) {
              valid = built;
              inherit invalid;
              expected = true;
            };
        in
          checkRows backend {
            "constructor rejects per-backend config" = constructorRejects (base // {${backend}.config = _: {};});
            "constructor rejects per-backend defaults" = constructorRejects (base // {${backend}.defaults.package = pkgs.hello;});
            "transform rejects per-backend config" = transformRejects (built // {${backend} = built.${backend} // {config = _: {};};});
            "transform rejects per-backend defaults" = transformRejects (built // {${backend} = built.${backend} // {defaults.package = pkgs.hello;};});
            "transform rejects retired defaults.outputPath" = transformRejects (built // {defaults = built.defaults // {outputPath = null;};});
          };
      in
        checkRows "record delivery seam" ({
            "constructor accepts an installPackage callback" = builtName (base // {hm.installPackage = _: pkgs.hello;}) == "testapp";
            "constructor accepts record-level config" = builtName (base // {config = _: {};}) == "testapp";
            "constructor rejects retired defaults.outputPath" = constructorRejects (base // {defaults = base.defaults // {outputPath = null;};});
          }
          // lib.genAttrs backends backendRows)
    );

    # `optionNamespaces` places the builder's option groups. A nested launcher
    # carries the package and the settable switch, with a read-only root
    # `enable`; nested pools carry each pool option and its normalized form.
    # A record without a package has no launcher: its reserved launcher
    # namespace declares nothing, and its switch stays at the root. Malformed
    # namespaces fail where the record is built and where it is read.
    factory-option-namespaces = mkTest "option-namespaces" (let
      base = {
        inherit pkgs;
        name = "testapp";
        surfaceSupport.rules = {};
        defaults.package = pkgs.hello;
      };
      namespaces = {
        launcher = ["cli"];
        pools = ["arm"];
      };
      valid = base // {optionNamespaces = namespaces;};
      record = build valid;
      invalid = {
        "launcher contains an empty segment" = namespaces // {launcher = [""];};
        "launcher is a string" = namespaces // {launcher = "cli";};
        "launcher is null" = namespaces // {launcher = null;};
        "launcher segment is not a string" = namespaces // {launcher = [1];};
        "namespace group is unknown" = namespaces // {other = ["x"];};
        "namespaces are not an attribute set" = "cli";
      };
      check = backend: let
        eval = config: evaluate backend [record] config;
        packages = evaluated:
          if backend == "hm"
          then evaluated.config.home.packages
          else evaluated.config.packages;
        normal = eval {
          ai.rules.root.text = "ROOT";
          ai.testapp = {
            cli.enable = true;
            arm.rules.local.text = "LOCAL";
          };
        };
        custom = evaluate backend [(record // {installPackage = _: throw "null package called installPackage";})] {
          ai.testapp.cli = {
            enable = true;
            package = null;
          };
        };
        withoutLauncher = evaluate backend [(build (removeAttrs valid ["defaults"]))] {ai.testapp.enable = true;};
      in
        checkRows "${backend} option namespaces" ({
            "a null package bypasses installation" = packages custom == [];
            "a record without a package keeps the root switch and no launcher" =
              withoutLauncher.config.ai.testapp.enable
              && packages withoutLauncher == []
              && !(withoutLauncher.options.ai.testapp ? cli)
              && withoutLauncher.options.ai.testapp.arm ? rules;
            "launcher enables and installs the package" = packages normal == [pkgs.hello] && normal.config.ai.testapp.enable;
            "package option is not at the runtime root" = !(normal.options.ai.testapp ? package);
            "rules merge in the nested pool, not at the runtime root" =
              !(normal.options.ai.testapp ? rules)
              && builtins.attrNames normal.config.ai.testapp.arm.normalized.rules == ["local" "root"];
          }
          // lib.mapAttrs (_: optionNamespaces:
            rejectsChange (input: runtimeEnabled backend input {}) {
              valid = record;
              invalid = record // {inherit optionNamespaces;};
              expected = false;
            })
          invalid);
    in
      checkRows "option namespaces" ({
          constructor = checkRows "constructor option namespaces" (lib.mapAttrs (_: optionNamespaces: rejectsRecord valid (base // {inherit optionNamespaces;})) invalid);
        }
        // lib.genAttrs backends check));

    # A native agent layer is one pair on the record, `agentNativeType` with
    # `agentTransformer`, and it lowers the agents pool. Either half alone, or
    # the pair on a record without that pool, must fail where the record is
    # built. The pair with the agents pool is the positive control.
    factory-mkRuntime-native-agent-contract = mkTest "mkRuntime-native-agent-contract" (
      let
        base = {
          inherit pkgs;
          name = "testapp";
          defaults.package = pkgs.hello;
        };
        withAgents = base // {surfaceSupport.agents.backends = backends;};
        nativeLayer = {
          agentNativeType = lib.types.attrsOf lib.types.anything;
          agentTransformer = _: _: {};
        };
        valid = withAgents // nativeLayer;
        rejects = rejectsRecord valid;
      in
        checkRows "native agent declaration" {
          "native layer requires an agents pool" = rejects (base // nativeLayer);
          "native type requires its transformer" = rejects (removeAttrs valid ["agentTransformer"]);
          "transformer requires its native type" = rejects (removeAttrs valid ["agentNativeType"]);
        }
    );

    # The record's `poolOptions` and the value its `sharedAgentsMd` callback
    # returns are read by name, so a key nothing reads would be dropped with
    # no error: a misspelt pool, a pool the builder does not declare
    # (`hooks`), one the record does not support, `agentsDir` without
    # `agents`, or a stray callback field such as `context` or `maxbytes`.
    # An `agents` override would shadow the builder's description, so it is
    # rejected too; `agentsDescriptionSuffix` is the runtime's hook, and it
    # and `agentsDirSuffixes` need the agents pool, the latter non-empty.
    # Each must fail, `poolOptions` both where the record is built and where a
    # transform reads it. The well-formed record, supported optional callback
    # fields, and a bare `key` are the positive controls.
    factory-mkRuntime-rejects-unread-record-keys = mkTest "mkRuntime-rejects-unread-record-keys" (
      let
        base = {
          inherit pkgs;
          name = "testapp";
          surfaceSupport = lib.genAttrs ["agents" "environmentVariables" "rules"] (_: {inherit backends;});
          defaults.package = pkgs.hello;
        };
        withoutAgents = base // {surfaceSupport = removeAttrs base.surfaceSupport ["agents"];};
        descriptionSuffix.agentsDescriptionSuffix = "Test agents.";
        valid =
          base
          // descriptionSuffix
          // {
            poolOptions = {
              agentsDir.description = "Test agents directory.";
              environmentVariables.description = "Test environment variables.";
            };
          };
        built = build valid;
        withPoolOptions = poolOptions: valid // {poolOptions = valid.poolOptions // poolOptions;};
        agentsDir = input: (evaluate "hm" [(build input)] {}).config.ai.testapp.agentsDir;
        agentsMdTarget = result: let
          record = build (valid // {sharedAgentsMd = _: result;});
        in
          (evaluate "devenv" [record] {ai.testapp.enable = true;}).config.ai.internal.agentsMdTargets.testapp;
        bareTarget.key = "AGENTS.md";
        rejectsTarget = invalid:
          rejectsChange agentsMdTarget {
            valid = bareTarget;
            inherit invalid;
            expected = "AGENTS.md";
          };
      in
        checkRows "closed runtime record and callback keys" ({
            "agents description suffix requires agents support" = rejectsRecord (base // descriptionSuffix) (withoutAgents // descriptionSuffix);
            "agents pool description cannot shadow the builder" = rejectsRecord valid (withPoolOptions {agents.description = "shadows the builder";});
            "agentsDir cannot override a missing agents pool" = rejectsRecord (base // {poolOptions.agentsDir.description = "Test agents directory.";}) (withoutAgents // {poolOptions.agentsDir.description = "Test agents directory.";});
            "agentsDir suffixes must be nonempty" = rejectsRecord (valid // {agentsDirSuffixes = [".json"];}) (valid // {agentsDirSuffixes = [];});
            "agentsDir suffixes must be strings" = rejectsRecord (valid // {agentsDirSuffixes = [".json"];}) (valid // {agentsDirSuffixes = [1];});
            "agentsDir suffixes require agents support" = rejectsRecord (base // {agentsDirSuffixes = [".md"];}) (withoutAgents // {agentsDirSuffixes = [".md"];});
            "callback accepts optional fields" =
              agentsMdTarget (bareTarget
                // {
                  maxBytes = 1024;
                  rules = {};
                })
              == "AGENTS.md";
            "callback rejects a lowercase maxbytes key" = rejectsTarget (bareTarget // {maxbytes = 1;});
            "callback rejects a stray context key" = rejectsTarget (bareTarget // {context = "stray";});
            "callback requires the target key" = rejectsChange agentsMdTarget {
              valid = bareTarget // {rules = {};};
              invalid = {rules = {};};
              expected = "AGENTS.md";
            };
            "constructor rejects a misspelt pool" = rejectsRecord valid (withPoolOptions {agnets.description = "misspelt";});
            "default agentsDir is null" = agentsDir valid == null;
            "even a supported surface cannot override an undeclared pool" = let
              withHooks = input: input // {surfaceSupport = input.surfaceSupport // {hooks = {inherit backends;};};};
            in
              rejectsRecord (withHooks valid) (withHooks (withPoolOptions {hooks.description = "undeclared";}));
            "pool override requires surface support" = rejectsRecord valid (valid // {surfaceSupport = removeAttrs valid.surfaceSupport ["environmentVariables"];});
            "suffix customization keeps the agentsDir default null" = agentsDir (valid // {agentsDirSuffixes = [".json"];}) == null;
          }
          // lib.genAttrs backends (backend:
            checkRows backend {
              "transform rejects a misspelt pool" = rejectsChange (input: runtimeEnabled backend input {ai.testapp.enable = true;}) {
                valid = built;
                invalid = built // {poolOptions = built.poolOptions // {agnets = {};};};
                expected = true;
              };
            }))
    );

    factory-mkRuntime-returns-record = mkTest "mkRuntime-returns-record" (
      let
        record = build {
          defaults.package = pkgs.hello;
          name = "testapp";
          surfaceSupport = {};
        };
      in
        checkRows "constructed runtime record" {
          "empty support stays empty" = record.surfaceSupport == {};
          "launcher default is retained" = record.defaults.package == pkgs.hello;
          "record retains its name" = record.name == "testapp";
        }
    );

    # A runtime declares each normalized field it consumes; surface support
    # alone does not imply support for a newly added field.
    factory-mkRuntime-settings-fields = mkTest "mkRuntime-settings-fields" (
      let
        backendReason = "Only devenv lacks settings delivery.";
        expected = backend: path: reason: "${path} is set but ${backend} does not deliver it to testapp (reason: ${reason})";
        fieldReason = "testapp's surfaceSupport.settings.fields does not consume this normalized setting.";
        testRecord = settings: pools:
          build {
            inherit pkgs;
            name = "testapp";
            optionNamespaces = {inherit pools;};
            surfaceSupport.settings = settings;
          };
        partialRecord = testRecord {
          backends = ["hm"];
          reason = backendReason;
        };
        supportedRecord = testRecord {fields = settingsFields;};
        unsupportedRecord = testRecord {};
      in
        lib.all (field: let
          root = {settings.${field} = settingSample field;};
        in
          lib.all (pools: let
            poolPath = ["testapp"] ++ pools;
            normalizedPath = poolPath ++ ["normalized" "settings" field];
            normalized = lib.setAttrByPath normalizedPath (resolvedSettingSample field);
            runtimePath = poolPath ++ ["settings" field];
            runtime = lib.setAttrByPath runtimePath (settingSample field);
            partialWarnings = backend: request: (evaluateSupport backend (partialRecord pools) request true).config.warnings;
          in
            partialWarnings "devenv" normalized
            == [(expected "devenv" (lib.showOption (["ai"] ++ normalizedPath)) backendReason)]
            && partialWarnings "hm" root == [(expected "hm" "ai.settings.${field}" fieldReason)]
            && partialWarnings "devenv" root == [(expected "devenv" "ai.settings.${field}" backendReason)]
            && lib.all (backend: let
              evaluate = request: (evaluateSupport backend (unsupportedRecord pools) request true).config;
              warnings = request: (evaluate request).warnings;
              runtimeWarning = [(expected backend (lib.showOption (["ai"] ++ runtimePath)) fieldReason)];
              supported = (evaluateSupport backend (supportedRecord pools) root true).config;
            in
              lib.attrByPath normalizedPath null supported.ai
              == resolvedSettingSample field
              && supported.warnings == []
              && lib.all (request: lib.getAttrFromPath normalizedPath (evaluate request).ai == null) [root runtime]
              && warnings root == [(expected backend "ai.settings.${field}" fieldReason)]
              && warnings runtime == runtimeWarning
              && warnings (lib.recursiveUpdate root runtime) == runtimeWarning
              && warnings normalized == [(expected backend (lib.showOption (["ai"] ++ normalizedPath)) fieldReason)]) ["devenv" "hm"]) [[] ["arm"]])
        settingsFields
    );

    # Only gaps on unlisted settings fields duplicate the default warning.
    factory-mkRuntime-settings-field-contract = mkTest "mkRuntime-settings-field-contract" (
      let
        base = {
          inherit pkgs;
          name = "testapp";
          surfaceSupport.settings = {
            backends = ["devenv" "hm"];
            fields = settingsFields;
          };
        };
        withSettings = support: base // {surfaceSupport.settings = base.surfaceSupport.settings // support;};
        gap = {
          path = ["reasoningEffort"];
          reason = "specific gap";
        };
        withGap = withSettings {gaps = [gap];};
        withSkills = base // {surfaceSupport.skills = {inherit backends;};};
      in
        checkRows "settings declarations" {
          "a consumed field can have a conditional gap" = builtName (withSettings {gaps = [(gap // {when = _: true;})];}) == "testapp";
          "a runtime can consume zero settings fields" = builtName (withSettings {fields = [];}) == "testapp";
          "fields are only allowed on settings" = rejectsRecord withSkills (base
            // {
              surfaceSupport.skills = {
                inherit backends;
                fields = settingsFields;
              };
            });
          "fields require at least one delivering backend" = rejectsRecord base (withSettings {backends = [];});
          "gap must name a consumed field" = rejectsRecord withGap (withSettings {
            fields = [];
            gaps = [gap];
          });
          "unknown normalized field is rejected" = rejectsRecord base (withSettings {fields = ["reasoning-effort"];});
        }
    );

    factory-mkRuntime-new-surfaces-warn = mkTest "mkRuntime-new-surfaces-warn" (
      let
        decompose = import ../../lib/ai/app/decompose.nix {inherit lib;};
        config.ai = {
          probeRoot = "requested";
          settings = {
            probeField = "requested";
            reasoningEffort = null;
          };
          testapp = {};
        };
        warnings = support:
          (decompose {
            appRecord = {
              name = "testapp";
              surfaceSupport = support;
            };
            backend = "hm";
            inherit config;
            entries = _: [];
            message = path: reason: "${lib.showOption path} is set but hm does not deliver it to testapp (reason: ${reason})";
            nonEmpty = value: value != null && value != "";
            present = _: value: value != null && value != "";
            sharedSurfaces = ["probeRoot" "settings"];
          }).warnings;
        unsupported = warnings {};
        supported = warnings {
          probeRoot = {backends = ["hm"];};
          settings = {
            backends = ["hm"];
            fields = ["probeField"];
          };
        };
      in
        checkRows "new surface diagnostics" {
          "declared consumers suppress both warnings" = supported == [];
          "undeclared root and settings fields each warn once" =
            unsupported
            == [
              "ai.probeRoot is set but hm does not deliver it to testapp (reason: testapp's surfaceSupport does not consume this shared surface.)"
              "ai.settings.probeField is set but hm does not deliver it to testapp (reason: testapp's surfaceSupport does not consume this shared surface.)"
            ];
        }
    );

    factory-mkRuntime-builds-option-tree = mkTest "mkRuntime-builds-option-tree" (
      let
        base = {
          name = "testapp";
          defaults.package = pkgs.hello;
        };
        launcherOnly = build base;
        withPool = build (base // {surfaceSupport.mcpServers = {inherit backends;};});
      in
        checkRows "default factory option tree" (lib.genAttrs backends (backend:
          checkRows backend {
            "launcher-only runtime is disabled by default" = !runtimeEnabled backend launcherOnly {};
            "supported MCP pool defaults to no servers" = (evaluate backend [withPool] {}).config.ai.testapp.mcpServers == {};
            "supporting an MCP pool leaves the launcher disabled by default" = !runtimeEnabled backend withPool {};
          }))
    );

    factory-mkRuntime-custom-options-merged = mkTest "mkRuntime-custom-options-merged" (
      let
        record = build {
          name = "testapp";
          surfaceSupport = {};
          defaults = {package = pkgs.hello;};
          options = {
            turboMode = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        };
      in
        (evaluate "hm" [record] {ai.testapp.turboMode = true;}).config.ai.testapp.turboMode
    );

    # A backend's option declaration replaces the record's at the same path as a
    # whole. Merged field by field, the record's attrset `default` keys would
    # survive in the backend's declaration; a group (`cli`) still joins.
    factory-mkRuntime-backend-option-replaces-shared-declaration = mkTest "mkRuntime-backend-option-replaces-shared-declaration" (
      let
        record = build {
          name = "testapp";
          surfaceSupport = {};
          defaults = {package = pkgs.hello;};
          options = {
            cli.shared = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            table = lib.mkOption {
              type = lib.types.attrsOf lib.types.int;
              default = {fromRecord = 1;};
            };
          };
          hm.options = {
            cli.backendOnly = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            table = lib.mkOption {
              type = lib.types.attrsOf lib.types.int;
              default = {};
            };
          };
        };
        cfg = (evaluate "hm" [record] {}).config.ai.testapp;
      in
        checkRows "backend option replacement" {
          "backend table does not inherit record default keys" = cfg.table == {};
          "option group keeps both backend and shared members" =
            cfg.cli
            == {
              backendOnly = true;
              shared = true;
            };
        }
    );

    factory-mkRuntime-fanout-merges-shared-servers = mkTest "mkRuntime-fanout-merges-shared-servers" (
      let
        # The harness callback exposes the maps passed to runtime delivery,
        # independently of any particular runtime's file format.
        server = command: {
          inherit command;
          package = pkgs.hello;
          type = "stdio";
        };
        cfg =
          (evaluate "hm" [(mkProxyTestRecord "testapp")] {
            ai = {
              mcpServers.shared = server "shared-mcp";
              testapp = {
                enable = true;
                mcpServers.local = server "local-mcp";
              };
            };
          }).config.ai.testapp;
      in
        builtins.mapAttrs (_: server: server.command) cfg._observedServers
        == {
          local = "local-mcp";
          shared = "shared-mcp";
        }
    );

    # Public mkRuntime records participate in centralized proxy ownership without
    # appearing in the repo's first-party runtime registry. A used inherited
    # owner is therefore the shared `internal` service, lowered for the custom
    # client. The harness stubs carry no ai-module lowering, so these cases
    # assert the owning service layer; unit shape is ai-module's own contract.
    factory-mkRuntime-custom-runtime-uses-shared-proxy-owner = mkTest "mkRuntime-custom-runtime-uses-shared-proxy-owner" (
      let
        cfg =
          (evaluateProxy "hm" [(mkProxyTestRecord "testapp")] {
            ai.mcpServers.shared = factoryProxyServer 9509;
            ai.testapp.enable = true;
          }).config.ai;
      in
        checkRows "custom runtime inherited proxy" {
          "client uses the shared listener" = cfg.testapp._observedServers.shared.url == "http://127.0.0.1:9509/";
          "internal is the sole claimant" = cfg.claims.service.mcp-proxy-shared == ["internal"];
          "internal owns the shared service" = cfg.internal.services ? mcp-proxy-shared;
        }
    );

    # A custom runtime-scoped declaration is a direct owner, exactly like a
    # first-party record, rather than merely a lowered dead-loopback client.
    factory-mkRuntime-custom-runtime-emits-direct-proxy-owner = mkTest "mkRuntime-custom-runtime-emits-direct-proxy-owner" (
      let
        cfg = (directProxy "hm" 9510).ai;
      in
        checkRows "custom Home Manager runtime direct proxy" {
          "client uses the runtime listener" = cfg.testapp._observedServers.direct.url == "http://127.0.0.1:9510/";
          "runtime is the sole claimant" = cfg.claims.service.mcp-proxy-direct == ["testapp"];
          "runtime owns the direct service" = cfg.testapp.services ? mcp-proxy-direct;
        }
    );

    # Dynamic registration also closes the security boundary across arbitrary
    # records: two direct owners cannot silently route through one daemon.
    factory-mkRuntime-custom-runtime-proxy-key-reuse-fails = mkTest "mkRuntime-custom-runtime-proxy-key-reuse-fails" (
      let
        failures = secondKey: let
          evaluated = evaluateProxy "hm" (map mkProxyTestRecord ["first" "second"]) {
            ai.first = proxyRuntime "shared" 9511;
            ai.second = proxyRuntime secondKey 9512;
          };
        in
          map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions);
      in
        checkRows "custom runtime proxy key ownership" {
          "separate keys avoid ownership conflicts" = failures "separate" == [];
          "shared key identifies both conflicting owners" =
            failures "shared"
            == [
              "ai.claims.service.mcp-proxy-shared: claimed by first and second"
            ];
        }
    );

    # A custom devenv runtime owns its proxy service the same way a first-party
    # one does; the factory's devenv stubs have no `processes`, so the service
    # entry stands in for the lowered process.
    factory-mkRuntime-custom-runtime-devenv-emits-direct-proxy-owner = mkTest "mkRuntime-custom-runtime-devenv-emits-direct-proxy-owner" (
      let
        cfg = directProxy "devenv" 9513;
      in
        checkRows "custom devenv runtime direct proxy" {
          "client uses the runtime listener" = cfg.ai.testapp._observedServers.direct.url == "http://127.0.0.1:9513/";
          "configuration has no failed assertions" = builtins.all (assertion: assertion.assertion) cfg.assertions;
          "runtime owns the direct service" = cfg.ai.testapp.services ? mcp-proxy-direct;
        }
    );

    # Same-named native options are independent when a normalized pool is not in
    # surfaceSupport. Proxy discovery keys on the internal capability marker, not
    # the public option name, so an arbitrary native shape remains untouched.
    factory-mkRuntime-unsupported-native-mcp-option-not-registered = mkTest "mkRuntime-unsupported-native-mcp-option-not-registered" (
      let
        record = build {
          inherit pkgs;
          name = "testapp";
          surfaceSupport = {};
          defaults.package = pkgs.hello;
          options.mcpServers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
          };
        };
        cfg = (evaluateProxy "hm" [record] {ai.testapp.mcpServers = ["native-only"];}).config;
      in
        checkRows "native-only MCP option" {
          "configuration has no failed assertions" = builtins.all (assertion: assertion.assertion) cfg.assertions;
          "native value survives unchanged" = cfg.ai.testapp.mcpServers == ["native-only"];
          "no runtime proxy service is registered" = cfg.ai.testapp.services == {};
          "no shared proxy service is registered" = cfg.ai.internal.services == {};
        }
    );
  };
}
