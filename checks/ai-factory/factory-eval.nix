# Factory contracts for this owner or shared primitive.
# cspell:ignore agnets maxbytes
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai devenvStubs factoryProxyServer hmStubs mkProxyTestRecord mkTest;
  sharedRequests = {
    agents.probe = {
      description = "probe";
      instructions.text = "probe";
    };
    context.text = "probe";
    environmentVariables.PROBE = "value";
    hooks.PreToolUse = [{hooks = [{command = "true";}];}];
    # A wholly unsupported MCP surface gets one surface diagnostic, even
    # when its transport would also drop fields on a capable runtime.
    mcpServers.probe = {
      command = "probe";
      headers.Authorization = "probe";
    };
    proxy = {
      key = (import ../../lib/redact {inherit lib;}).file "/run/secrets/ai-proxy-key";
      url = "http://127.0.0.1:8317";
    };
    rules.probe.text = "probe";
    settings.reasoningEffort = "high";
    shell = pkgs.bash;
    skills.probe = ../../packages/claude-code/checks/fixtures/claude-skills/skill-a;
  };
  evaluateSupport = backend: record: requests: enabled:
    lib.evalModules {
      modules = [
        ai.sharedOptions
        (
          if backend == "hm"
          then hmStubs
          else devenvStubs
        )
        {
          options.warnings = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
          };
        }
        (ai.app.${backend + "Transform"} record)
        {config.ai = lib.recursiveUpdate requests (lib.setAttrByPath [record.name "enable"] enabled);}
      ];
    };
  decomposeCase = backend: surfaceSupport: let
    record = ai.app.mkRuntime {
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
    supportedSurfaces = builtins.attrNames (lib.filterAttrs (_: support: support.backends != []) record.surfaceSupport);
    unsupported = lib.subtractLists supportedSurfaces evaluated.config.ai.internal.sharedSurfaces;
  in
    # Every registered surface is exercised, and each unsupported surface
    # gets exactly one diagnostic through the public factory on both backends.
    builtins.attrNames sharedRequests
    == evaluated.config.ai.internal.sharedSurfaces
    && builtins.length warnings == builtins.length unsupported
    && lib.all (surface:
      builtins.length (lib.filter
        (lib.hasPrefix "ai.${surface} is set but ${backend} does not deliver it to testapp (reason: ")
        warnings)
      == 1)
    unsupported
    && lib.all (surface: !(lib.any (lib.hasPrefix "ai.${surface} is set but ") warnings)) supportedSurfaces
    && (evaluate {} true).config.warnings == []
    && (evaluate sharedRequests false).config.warnings == []
    && (!(builtins.elem "skills" supportedSurfaces) || evaluated.config.ai.testapp.normalized.skills == sharedRequests.skills);
in {
  checks = {
    factory-mkRuntime-decompose-no-surfaces = mkTest "mkRuntime-decompose-no-surfaces" (
      lib.all (backend: decomposeCase backend {} && decomposeCase backend {skills.backends = [];}) ["devenv" "hm"]
    );
    factory-mkRuntime-decompose-one-surface = mkTest "mkRuntime-decompose-one-surface" (
      lib.all (backend: decomposeCase backend {skills.backends = ["devenv" "hm"];}) ["devenv" "hm"]
    );
    factory-mkRuntime-declared-backend-support = mkTest "mkRuntime-declared-backend-support" (
      let
        reason = "Only Home Manager delivers this surface.";
        record = ai.app.mkRuntime {
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
        lib.all (
          backend: let
            evaluate = requests: enabled: (evaluateSupport backend record requests enabled).config;
            expected = path: lib.optional (backend == "devenv") (warning backend path);
          in
            (evaluate request true).warnings
            == expected "ai.agents"
            && (evaluate {testapp.agents = request.agents;} true).warnings == expected "ai.testapp.agents"
            && (evaluate (request // {testapp.agents.probe = null;}) true).warnings == []
            && (evaluate {} true).warnings == []
            && (evaluate request false).warnings == []
            && (evaluate request true).ai.testapp.normalized.agents.probe.description == "probe"
        ) ["devenv" "hm"]
    );
    factory-mkRuntime-declared-nested-gap = mkTest "mkRuntime-declared-nested-gap" (
      let
        reason = "This runtime has no portable tool allowlist.";
        record = ai.app.mkRuntime {
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
        lib.all (
          backend: let
            warnings = requests: enabled: (evaluateSupport backend record requests enabled).config.warnings;
            expected = path: ["${path}.tools is set but ${backend} does not deliver it to testapp (reason: ${reason})"];
          in
            warnings request true
            == expected "ai.agents.probe"
            && warnings {testapp.agents = request.agents;} true == expected "ai.testapp.agents.probe"
            && warnings (request // {testapp.agents.probe = null;}) true == []
            && warnings (request // {testapp.agents.probe = sharedRequests.agents.probe;}) true == []
            && warnings {agents.probe = sharedRequests.agents.probe // {tools = [];};} true == []
            && warnings {} true == []
            && warnings request false == []
        ) ["devenv" "hm"]
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
        built = ai.app.mkRuntime base;
        rejected = record: !(builtins.tryEval (ai.app.mkRuntime record)).success;
        transformed = backend: record:
          builtins.tryEval
          (lib.evalModules {
            modules = [
              ai.sharedOptions
              (
                if backend == "hm"
                then hmStubs
                else devenvStubs
              )
              (ai.app.${backend + "Transform"} record)
              {config.ai.testapp.enable = true;}
            ];
          })
          .config
          .ai
          .testapp
          .enable;
        rejectedByTransform = backend: record: !(transformed backend record).success;
      in
        lib.all (backend:
          rejected (base // {${backend}.config = _: {};})
          && rejected (base // {${backend}.defaults.package = pkgs.hello;})
          && rejectedByTransform backend (built // {${backend} = built.${backend} // {config = _: {};};})
          && rejectedByTransform backend (built // {${backend} = built.${backend} // {defaults.package = pkgs.hello;};})
          && rejectedByTransform backend (built // {defaults = built.defaults // {outputPath = null;};})
          && (transformed backend built).success)
        ["devenv" "hm"]
        && rejected (base // {defaults.outputPath = null;})
        && (builtins.tryEval (ai.app.mkRuntime (base // {config = _: {};}))).success
        && (builtins.tryEval (ai.app.mkRuntime (base // {hm.installPackage = _: pkgs.hello;}))).success
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
      transformed = backend: record: config:
        lib.evalModules {
          modules = [
            ai.sharedOptions
            (
              if backend == "hm"
              then hmStubs
              else devenvStubs
            )
            (ai.app.${backend + "Transform"} record)
            {inherit config;}
          ];
        };
      invalid = ["cli" {launcher = "cli";} {launcher = [""];} {launcher = [1];} {launcher = null;} {other = ["x"];}];
      check = backend: let
        record = ai.app.mkRuntime (base
          // {
            optionNamespaces = {
              launcher = ["cli"];
              pools = ["arm"];
            };
          });
        eval = config: transformed backend record config;
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
        custom = transformed backend (record // {installPackage = _: throw "null package called installPackage";}) {
          ai.testapp.cli = {
            enable = true;
            package = null;
          };
        };
        withoutLauncher = transformed backend (ai.app.mkRuntime (builtins.removeAttrs base ["defaults"]
          // {
            optionNamespaces = {
              launcher = ["cli"];
              pools = ["arm"];
            };
          })) {ai.testapp.enable = true;};
      in
        packages normal
        == [pkgs.hello]
        && normal.config.ai.testapp.enable
        && packages custom == []
        && !(normal.options.ai.testapp ? package)
        && !(normal.options.ai.testapp ? rules)
        && builtins.attrNames normal.config.ai.testapp.arm.normalized.rules == ["local" "root"]
        && withoutLauncher.config.ai.testapp.enable
        && packages withoutLauncher == []
        && !(withoutLauncher.options.ai.testapp ? cli)
        && withoutLauncher.options.ai.testapp.arm ? rules
        && lib.all (namespaces:
          !(builtins.tryEval (ai.app.mkRuntime (base // {optionNamespaces = namespaces;}))).success
          && !(builtins.tryEval (transformed backend (record // {optionNamespaces = namespaces;}) {}).config.ai.testapp.enable).success)
        invalid;
    in
      lib.all check ["devenv" "hm"]);

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
        withAgents = base // {surfaceSupport = lib.genAttrs ["agents"] (_: {backends = ["devenv" "hm"];});};
        rejected = record: !(builtins.tryEval (ai.app.mkRuntime record)).success;
        nativeLayer = {
          agentNativeType = lib.types.attrsOf lib.types.anything;
          agentTransformer = _: _: {};
        };
      in
        rejected (withAgents // {inherit (nativeLayer) agentNativeType;})
        && rejected (withAgents // {inherit (nativeLayer) agentTransformer;})
        && rejected (base // nativeLayer)
        && (builtins.tryEval (ai.app.mkRuntime (withAgents // nativeLayer))).success
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
    # transform reads it. The well-formed record, every callback field, and a
    # bare `key` are the positive controls.
    factory-mkRuntime-rejects-unread-record-keys = mkTest "mkRuntime-rejects-unread-record-keys" (
      let
        base = {
          inherit pkgs;
          name = "testapp";
          surfaceSupport = lib.genAttrs ["agents" "environmentVariables" "rules"] (_: {backends = ["devenv" "hm"];});
          defaults.package = pkgs.hello;
          agentsDescriptionSuffix = "Test agents.";
          poolOptions = {
            agentsDir.description = "Test agents directory.";
            environmentVariables.description = "Test environment variables.";
          };
        };
        built = ai.app.mkRuntime base;
        rejected = record: !(builtins.tryEval (ai.app.mkRuntime record)).success;
        evaluate = backend: record:
          (lib.evalModules {
            modules = [
              ai.sharedOptions
              (
                if backend == "hm"
                then hmStubs
                else devenvStubs
              )
              (ai.app.${backend + "Transform"} record)
              {config.ai.testapp.enable = true;}
            ];
          })
          .config;
        transformed = backend: record: builtins.tryEval (evaluate backend record).ai.testapp.enable;
        withPoolOptions = poolOptions: base // {poolOptions = base.poolOptions // poolOptions;};
        agentsMdTarget = sharedAgentsMd:
          builtins.tryEval
          (evaluate "devenv" (ai.app.mkRuntime (base // {inherit sharedAgentsMd;})))
          .ai
          .internal
          .agentsMdTargets
          .testapp;
        rejectedResult = result: !(agentsMdTarget (_: result)).success;
        publishes = result:
          agentsMdTarget (_: result)
          == {
            success = true;
            value = "AGENTS.md";
          };
      in
        rejected (withPoolOptions {agnets.description = "misspelt";})
        && rejected (withPoolOptions {agents.description = "shadows the builder";})
        && rejected (base // {surfaceSupport = removeAttrs base.surfaceSupport ["environmentVariables"];})
        && rejected (base // {agentsDirSuffixes = [];})
        && rejected (base // {agentsDirSuffixes = [1];})
        && rejected ((removeAttrs base ["poolOptions"])
          // {
            surfaceSupport = lib.genAttrs ["rules"] (_: {backends = ["devenv" "hm"];});
            agentsDescriptionSuffix = "no agents pool";
          })
        && rejected ((removeAttrs base ["poolOptions" "agentsDescriptionSuffix"])
          // {
            surfaceSupport = lib.genAttrs ["rules"] (_: {backends = ["devenv" "hm"];});
            agentsDirSuffixes = [".md"];
          })
        && rejected (withPoolOptions {hooks.description = "undeclared";} // {surfaceSupport = base.surfaceSupport // {hooks.backends = ["devenv" "hm"];};})
        && rejected ((removeAttrs base ["agentsDescriptionSuffix"])
          // {
            surfaceSupport = lib.genAttrs ["rules"] (_: {backends = ["devenv" "hm"];});
            poolOptions.agentsDir.description = "no agents pool";
          })
        && lib.all (backend:
          !(transformed backend (built // {poolOptions = built.poolOptions // {agnets = {};};})).success
          && (transformed backend built).success)
        ["devenv" "hm"]
        && (evaluate "hm" built).ai.testapp.agentsDir == null
        && (evaluate "hm" (ai.app.mkRuntime (base // {agentsDirSuffixes = [".json"];}))).ai.testapp.agentsDir == null
        && rejectedResult {
          key = "AGENTS.md";
          maxbytes = 1;
        }
        && rejectedResult {
          key = "AGENTS.md";
          context = "stray";
        }
        && rejectedResult {rules = {};}
        && publishes {key = "AGENTS.md";}
        && publishes {
          key = "AGENTS.md";
          maxBytes = 1024;
          rules = {};
        }
    );

    factory-mkRuntime-hmTransform-exists = mkTest "mkRuntime-hmTransform-exists" (
      builtins.isFunction ai.app.hmTransform
    );

    factory-mkRuntime-devenvTransform-exists = mkTest "mkRuntime-devenvTransform-exists" (
      builtins.isFunction ai.app.devenvTransform
    );

    factory-mkRuntime-returns-record = mkTest "mkRuntime-returns-record" (
      let
        record = ai.app.mkRuntime {
          name = "testapp";
          surfaceSupport = {};
          defaults.package = pkgs.hello;
        };
      in
        record ? name
        && record ? defaults
        && record.surfaceSupport == {}
    );

    # A runtime outside this repository declares normalized settings and any
    # field it cannot deliver through surfaceSupport.settings.gaps. Supporting
    # settings alone must not invent a reasoning-effort gap. The root value
    # reaches the normalized option here, so quiet is declared support rather
    # than an unread input; no first-party policy row speaks for this runtime.
    factory-mkRuntime-no-generic-effort-warning = mkTest "mkRuntime-no-generic-effort-warning" (
      let
        record = ai.app.mkRuntime {
          inherit pkgs;
          name = "testapp";
          surfaceSupport = lib.genAttrs ["settings"] (_: {backends = ["devenv" "hm"];});
          defaults.package = pkgs.hello;
        };
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            hmStubs
            {
              options.warnings = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [];
              };
            }
            (ai.app.hmTransform record)
            {
              config.ai = {
                settings.reasoningEffort = "high";
                testapp.enable = true;
              };
            }
          ];
        };
      in
        evaluated.config.ai.testapp.normalized.settings.reasoningEffort
        == "high"
        && !(lib.any (lib.hasInfix "reasoningEffort") evaluated.config.warnings)
    );

    factory-mkRuntime-builds-option-tree = mkTest "mkRuntime-builds-option-tree" (
      let
        record = ai.app.mkRuntime {
          name = "testapp";
          surfaceSupport = lib.genAttrs ["mcpServers"] (_: {backends = ["devenv" "hm"];});
          defaults.package = pkgs.hello;
        };
        module = ai.app.hmTransform record;
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            hmStubs
            module
            {config = {};}
          ];
        };
      in
        !evaluated.config.ai.testapp.enable
        && evaluated.config.ai.testapp.mcpServers == {}
    );

    factory-mkRuntime-custom-options-merged = mkTest "mkRuntime-custom-options-merged" (
      let
        record = ai.app.mkRuntime {
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
        module = ai.app.hmTransform record;
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            hmStubs
            module
            {config.ai.testapp.turboMode = true;}
          ];
        };
      in
        evaluated.config.ai.testapp.turboMode
    );

    factory-mkRuntime-fanout-merges-shared-servers = mkTest "mkRuntime-fanout-merges-shared-servers" (
      let
        record = ai.app.mkRuntime {
          name = "testapp";
          surfaceSupport = lib.genAttrs ["mcpServers"] (_: {backends = ["devenv" "hm"];});
          defaults = {package = pkgs.hello;};
          options = {
            # Synthetic introspection option — NOT part of the real mkRuntime contract,
            # only used here to prove mergedServers is computed and accessible to
            # the delivery callback.
            _mergedServerCount = lib.mkOption {
              type = lib.types.int;
              default = 0;
            };
          };
          config = {mergedServers, ...}: {
            ai.testapp._mergedServerCount = builtins.length (builtins.attrNames mergedServers);
          };
        };
        module = ai.app.hmTransform record;
        evaluated = lib.evalModules {
          modules = [
            (import ../../lib/ai/sharedOptions.nix)
            hmStubs
            module
            {
              config = {
                ai = {
                  mcpServers.shared = {
                    type = "stdio";
                    package = pkgs.hello;
                    command = "hello";
                  };
                  testapp = {
                    enable = true;
                    mcpServers.local = {
                      type = "stdio";
                      package = pkgs.hello;
                      command = "hello";
                    };
                  };
                };
              };
            }
          ];
        };
      in
        evaluated.config.ai.testapp._mergedServerCount == 2
    );

    # Public mkRuntime records participate in centralized proxy ownership without
    # appearing in the repo's first-party runtime registry. A used inherited
    # owner is therefore the shared `internal` service, lowered for the custom
    # client. The harness stubs carry no ai-module lowering, so these cases
    # assert the owning service layer; unit shape is ai-module's own contract.
    factory-mkRuntime-custom-runtime-uses-shared-proxy-owner = mkTest "mkRuntime-custom-runtime-uses-shared-proxy-owner" (
      let
        record = mkProxyTestRecord "testapp";
        evaluated = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            ai.sharedOptions
            hmStubs
            (ai.app.hmTransform record)
            {
              config.ai = {
                mcpServers.shared = factoryProxyServer 9509;
                testapp.enable = true;
              };
            }
          ];
        };
      in
        evaluated.config.ai.internal.services ? mcp-proxy-shared
        && evaluated.config.ai.claims.service.mcp-proxy-shared == ["internal"]
        && evaluated.config.ai.testapp._observedServers.shared.url == "http://127.0.0.1:9509/"
    );

    # A custom runtime-scoped declaration is a direct owner, exactly like a
    # first-party record, rather than merely a lowered dead-loopback client.
    factory-mkRuntime-custom-runtime-emits-direct-proxy-owner = mkTest "mkRuntime-custom-runtime-emits-direct-proxy-owner" (
      let
        record = mkProxyTestRecord "testapp";
        evaluated = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            ai.sharedOptions
            hmStubs
            (ai.app.hmTransform record)
            {
              config.ai.testapp = {
                enable = true;
                mcpServers.direct = factoryProxyServer 9510;
              };
            }
          ];
        };
      in
        evaluated.config.ai.testapp.services ? mcp-proxy-direct
        && evaluated.config.ai.claims.service.mcp-proxy-direct == ["testapp"]
        && evaluated.config.ai.testapp._observedServers.direct.url == "http://127.0.0.1:9510/"
    );

    # Dynamic registration also closes the security boundary across arbitrary
    # records: two direct owners cannot silently route through one daemon.
    factory-mkRuntime-custom-runtime-proxy-key-reuse-fails = mkTest "mkRuntime-custom-runtime-proxy-key-reuse-fails" (
      let
        evaluated = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            ai.sharedOptions
            hmStubs
            (ai.app.hmTransform (mkProxyTestRecord "first"))
            (ai.app.hmTransform (mkProxyTestRecord "second"))
            {
              config.ai = {
                first = {
                  enable = true;
                  mcpServers.shared = factoryProxyServer 9511;
                };
                second = {
                  enable = true;
                  mcpServers.shared = factoryProxyServer 9512;
                };
              };
            }
          ];
        };
        failed = map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions);
      in
        builtins.elem "ai.claims.service.mcp-proxy-shared: claimed by first and second" failed
    );

    # A custom devenv runtime owns its proxy service the same way a first-party
    # one does; the factory's devenv stubs have no `processes`, so the service
    # entry stands in for the lowered process.
    factory-mkRuntime-custom-runtime-devenv-emits-direct-proxy-owner = mkTest "mkRuntime-custom-runtime-devenv-emits-direct-proxy-owner" (
      let
        record = mkProxyTestRecord "testapp";
        evaluated = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            ai.sharedOptions
            devenvStubs
            (ai.app.devenvTransform record)
            {
              config.ai.testapp = {
                enable = true;
                mcpServers.direct = factoryProxyServer 9513;
              };
            }
          ];
        };
      in
        builtins.all (assertion: assertion.assertion) evaluated.config.assertions
        && evaluated.config.ai.testapp.services ? mcp-proxy-direct
        && evaluated.config.ai.testapp._observedServers.direct.url == "http://127.0.0.1:9513/"
    );

    # Same-named native options are independent when a normalized pool is not in
    # surfaceSupport. Proxy discovery keys on the internal capability marker, not
    # the public option name, so an arbitrary native shape remains untouched.
    factory-mkRuntime-unsupported-native-mcp-option-not-registered = mkTest "mkRuntime-unsupported-native-mcp-option-not-registered" (
      let
        record = ai.app.mkRuntime {
          inherit pkgs;
          name = "testapp";
          surfaceSupport = {};
          defaults.package = pkgs.hello;
          options.mcpServers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
          };
        };
        evaluated = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            ai.sharedOptions
            hmStubs
            (ai.app.hmTransform record)
            {config.ai.testapp.mcpServers = ["native-only"];}
          ];
        };
      in
        evaluated.config.ai.testapp.mcpServers
        == ["native-only"]
        && evaluated.config.ai.internal.services == {}
        && evaluated.config.ai.testapp.services == {}
        && builtins.all (assertion: assertion.assertion) evaluated.config.assertions
    );

    factory-hmTransform-applies-to-record = mkTest "hmTransform-applies-to-record" (
      let
        record = ai.app.mkRuntime {
          name = "testapp";
          surfaceSupport = {};
          defaults.package = pkgs.hello;
        };
        module = ai.app.hmTransform record;
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            hmStubs
            module
            {config = {};}
          ];
        };
      in
        !evaluated.config.ai.testapp.enable
    );

    factory-devenvTransform-applies-to-record = mkTest "devenvTransform-applies-to-record" (
      let
        record = ai.app.mkRuntime {
          name = "testapp";
          surfaceSupport = {};
          defaults.package = pkgs.hello;
        };
        module = ai.app.devenvTransform record;
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            devenvStubs
            module
            {config = {};}
          ];
        };
      in
        !evaluated.config.ai.testapp.enable
    );
  };
}
