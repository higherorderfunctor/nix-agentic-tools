# Factory contracts for this owner or shared primitive.
# cspell:ignore agnets maxbytes
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai devenvStubs factoryProxyServer hmStubs mkProxyTestRecord mkTest;
in {
  checks = {
    # ── mkRuntime tests ───────────────────────────────────────────────
    # The per-backend seam is retired: delivery is ONE record-level `config`,
    # and a backend spec takes only installPackage, migrationConfig and
    # options. A record still written against the seam must fail loudly
    # rather than evaluate to a runtime that delivers nothing, both where the
    # record is built and where a transform reads it: the exported records are
    # plain attrsets, so an override (`r // {hm = …;}`) or a hand-built record
    # reaches `hmTransform` / `devenvTransform` without passing `mkRuntime`.
    # The record-level `config` and the untouched record are the positive
    # controls.
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
        && (builtins.tryEval (ai.app.mkRuntime (base // {hm.installPackage = null;}))).success
    );

    # The record's `poolOptions` and the value its `sharedAgentsMd` callback
    # returns are read by name, so a key nothing reads would be dropped with
    # no error: a misspelt pool, a pool the builder does not declare
    # (`hooks`), one the record does not support, `agentsDir` without
    # `agents`, or a stray callback field such as `context` or `maxbytes`.
    # Each must fail, `poolOptions` both where the record is built and where a
    # transform reads it. The well-formed record, every callback field, and a
    # bare `key` are the positive controls.
    factory-mkRuntime-rejects-unread-record-keys = mkTest "mkRuntime-rejects-unread-record-keys" (
      let
        base = {
          inherit pkgs;
          name = "testapp";
          supportedPools = ["agents" "lspServers" "rules"];
          defaults.package = pkgs.hello;
          poolOptions = {
            agents.description = "Test agents.";
            agentsDir.description = "Test agents directory.";
            lspServers.description = "Test LSP servers.";
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
        && rejected (withPoolOptions {environmentVariables.description = "unsupported";})
        && rejected (withPoolOptions {hooks.description = "undeclared";} // {supportedPools = base.supportedPools ++ ["hooks"];})
        && rejected (base
          // {
            supportedPools = ["lspServers"];
            poolOptions.agentsDir.description = "no agents pool";
          })
        && lib.all (backend:
          !(transformed backend (built // {poolOptions = built.poolOptions // {agnets = {};};})).success
          && (transformed backend built).success)
        ["devenv" "hm"]
        && (evaluate "hm" built).ai.testapp.agentsDir == null
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
          supportedPools = [];
          defaults.package = pkgs.hello;
        };
      in
        record ? name
        && record ? defaults
        && record.supportedPools == []
    );

    # A runtime record outside this repository may support the normalized
    # `settings` pool without lowering reasoning effort. No generic warning
    # speaks for it any more: the old one fired for every such runtime whether
    # or not it lowered effort. Disclosure belongs to the runtime's own
    # delivery `config`, which is merged into module config and can emit
    # `warnings` for the fields it drops. The repository's delivery rows cannot
    # do it, because they cover only this repository's runtimes. The control
    # is that the root value did reach the runtime's normalized settings, so
    # the silence is not an unread value.
    factory-mkRuntime-no-generic-effort-warning = mkTest "mkRuntime-no-generic-effort-warning" (
      let
        record = ai.app.mkRuntime {
          inherit pkgs;
          name = "testapp";
          supportedPools = ["settings"];
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
          supportedPools = ["mcpServers"];
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
          supportedPools = [];
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
          supportedPools = ["mcpServers"];
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
    # owner must therefore materialize once and lower for the custom client.
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
        evaluated.config.systemd.user.services ? mcp-proxy-shared
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
        evaluated.config.systemd.user.services ? mcp-proxy-direct
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
                first.mcpServers.shared = factoryProxyServer 9511;
                second.mcpServers.shared = factoryProxyServer 9512;
              };
            }
          ];
        };
        failed = builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions;
      in
        !(evaluated.config.systemd.user.services ? mcp-proxy-shared)
        && builtins.any
        (assertion:
          lib.hasInfix "ai.first.mcpServers.shared" assertion.message
          && lib.hasInfix "ai.second.mcpServers.shared" assertion.message)
        failed
    );

    # Custom devenv runtimes fail closed at the same explicit lifecycle boundary
    # as first-party ones; a lowered client entry cannot silently survive alone.
    factory-mkRuntime-custom-runtime-devenv-proxy-rejected = mkTest "mkRuntime-custom-runtime-devenv-proxy-rejected" (
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
        failed = builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions;
      in
        builtins.any
        (assertion:
          lib.hasInfix "ai.testapp.mcpServers" assertion.message
          && lib.hasInfix "devenv lifecycle is tracked separately" assertion.message)
        failed
    );

    # Same-named native options are independent when a normalized pool is not in
    # supportedPools. Proxy discovery keys on the internal capability marker, not
    # the public option name, so an arbitrary native shape remains untouched.
    factory-mkRuntime-unsupported-native-mcp-option-not-registered = mkTest "mkRuntime-unsupported-native-mcp-option-not-registered" (
      let
        record = ai.app.mkRuntime {
          inherit pkgs;
          name = "testapp";
          supportedPools = [];
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
        proxyServices = lib.filterAttrs (name: _: lib.hasPrefix "mcp-proxy-" name) evaluated.config.systemd.user.services;
      in
        evaluated.config.ai.testapp.mcpServers
        == ["native-only"]
        && proxyServices == {}
        && builtins.all (assertion: assertion.assertion) evaluated.config.assertions
    );

    factory-hmTransform-applies-to-record = mkTest "hmTransform-applies-to-record" (
      let
        record = ai.app.mkRuntime {
          name = "testapp";
          supportedPools = [];
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
          supportedPools = [];
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
