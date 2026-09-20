# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai devenvStubs factoryProxyServer hmStubs mkProxyTestRecord mkTest;
in {
  checks = {
    factory-mkAiApp-rejects-backend-config = mkTest "mkAiApp-rejects-backend-config" (
      let
        base = {
          name = "testapp";
          transformers.markdown = ai.transformers.claude;
        };
      in
        lib.all (backend:
          !(builtins.tryEval (ai.app.mkAiApp (base
            // {
              ${backend}.config = _: {};
            }))).success) ["devenv" "hm"]
        && (builtins.tryEval (ai.app.mkAiApp (base // {config = _: {};}))).success
    );

    # ── mkAiApp tests ───────────────────────────────────────────────
    factory-mkAiApp-hmTransform-exists = mkTest "mkAiApp-hmTransform-exists" (
      builtins.isFunction ai.app.hmTransform
    );

    factory-mkAiApp-devenvTransform-exists = mkTest "mkAiApp-devenvTransform-exists" (
      builtins.isFunction ai.app.devenvTransform
    );

    factory-mkAiApp-returns-record = mkTest "mkAiApp-returns-record" (
      let
        record = ai.app.mkAiApp {
          name = "testapp";
          supportedPools = [];
          transformers.markdown = ai.transformers.claude;
          defaults = {
            package = pkgs.hello;
            outputPath = ".config/test/CONFIG.md";
          };
        };
      in
        record ? name
        && record ? transformers
        && record ? defaults
        && record.supportedPools == []
    );

    factory-mkAiApp-builds-option-tree = mkTest "mkAiApp-builds-option-tree" (
      let
        record = ai.app.mkAiApp {
          name = "testapp";
          supportedPools = ["mcpServers"];
          transformers.markdown = ai.transformers.claude;
          defaults = {
            package = pkgs.hello;
            outputPath = ".config/test/CONFIG.md";
          };
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

    factory-mkAiApp-custom-options-merged = mkTest "mkAiApp-custom-options-merged" (
      let
        record = ai.app.mkAiApp {
          name = "testapp";
          supportedPools = [];
          transformers.markdown = ai.transformers.claude;
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

    factory-mkAiApp-fanout-merges-shared-servers = mkTest "mkAiApp-fanout-merges-shared-servers" (
      let
        record = ai.app.mkAiApp {
          name = "testapp";
          supportedPools = ["mcpServers"];
          transformers.markdown = ai.transformers.claude;
          defaults = {package = pkgs.hello;};
          options = {
            # Synthetic introspection option — NOT part of the real mkAiApp contract,
            # only used here to prove mergedServers is computed and accessible to
            # the config callback.
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

    # Public mkAiApp records participate in centralized proxy ownership without
    # appearing in the repo's first-party runtime registry. A used inherited
    # owner must therefore materialize once and lower for the custom client.
    factory-mkAiApp-custom-runtime-uses-shared-proxy-owner = mkTest "mkAiApp-custom-runtime-uses-shared-proxy-owner" (
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
    factory-mkAiApp-custom-runtime-emits-direct-proxy-owner = mkTest "mkAiApp-custom-runtime-emits-direct-proxy-owner" (
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
    factory-mkAiApp-custom-runtime-proxy-key-reuse-fails = mkTest "mkAiApp-custom-runtime-proxy-key-reuse-fails" (
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
    factory-mkAiApp-custom-runtime-devenv-proxy-rejected = mkTest "mkAiApp-custom-runtime-devenv-proxy-rejected" (
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
    factory-mkAiApp-unsupported-native-mcp-option-not-registered = mkTest "mkAiApp-unsupported-native-mcp-option-not-registered" (
      let
        record = ai.app.mkAiApp {
          inherit pkgs;
          name = "testapp";
          supportedPools = [];
          transformers.markdown = ai.transformers.claude;
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
        record = ai.app.mkAiApp {
          name = "testapp";
          supportedPools = [];
          transformers.markdown = ai.transformers.claude;
          defaults = {
            package = pkgs.hello;
            outputPath = ".config/test/CONFIG.md";
          };
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
        record = ai.app.mkAiApp {
          name = "testapp";
          supportedPools = [];
          transformers.markdown = ai.transformers.claude;
          defaults = {
            package = pkgs.hello;
            outputPath = ".config/test/CONFIG.md";
          };
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
