{
  lib,
  pkgs,
  harness,
  ...
}: let
  ai = import ../ai {inherit lib;};
  aiCommon = import ../ai/ai-common.nix {inherit lib;};

  # Stub HM option types so mkAiApp's baseline home.file render
  # (introduced when the render pipeline was wired) can write to
  # home.file.* without importing home-manager. Mirrors the
  # hmStubs pattern in lib/testing/module-harness.nix.
  hmStubs = {
    options = {
      # sharedOptions detects this option path to select the Home Manager
      # managed-proxy lifecycle. The real module supplies it; the factory
      # harness declares the same boundary without importing Home Manager.
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      home = {
        activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        file = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        # Required since package installation moved into the shared backend
        # transform: it writes `home.packages` for every ENABLED runtime, and
        # this harness enables several. Without the stub the module system
        # throws "The option `home.packages' does not exist" before any test
        # assertion runs, so the error names the option and never mentions the
        # test's actual subject.
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [];
        };
      };
    };
  };

  devenvStubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      files = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      # devenv's counterpart to the `home.packages` stub above — same reason.
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
    };
  };

  factoryProxyServer = port: {
    type = "http";
    url = "https://upstream.example.test/mcp";
    proxy = {
      enable = true;
      inherit port;
    };
  };

  mkProxyTestRecord = name:
    ai.app.mkAiApp {
      inherit name pkgs;
      supportedPools = ["mcpServers"];
      transformers.markdown = ai.transformers.claude;
      defaults.package = pkgs.hello;
      options._observedServers = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        internal = true;
      };
      hm.config = {mergedServers, ...}: {
        ai.${name}._observedServers = mergedServers;
      };
      devenv.config = {mergedServers, ...}: {
        ai.${name}._observedServers = mergedServers;
      };
    };
  mkTest = harness.mkAssertion "factory-test";

  # Exercise each mkBackendTransform call site through two real factory
  # records. Runtime A suppresses one inherited key and replaces another;
  # runtime B is the positive control that keeps both root entries. The
  # callback is a synthetic emitter only so the exact post-merge pool remains
  # observable without coupling this factory suite to one product's file
  # format.
  poolMergeContract = {
    poolName,
    rootValue,
    runtimeValue,
    checkRoot,
    checkRuntime,
  }: let
    mergedArgByPool = {
      agents = "mergedAgents";
      environmentVariables = "mergedEnvironmentVariables";
      lspServers = "mergedLspServers";
      mcpServers = "mergedServers";
      rules = "mergedRules";
      skills = "mergedSkills";
    };
    mergedArg = mergedArgByPool.${poolName};
    customPoolOptions = {
      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr ai.agent.agentType);
        default = {};
      };
      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
        default = {};
      };
      lspServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr aiCommon.lspServerModule);
        default = {};
      };
    };
    runtimeA = "pool-a-${poolName}";
    runtimeB = "pool-b-${poolName}";
    mkRecord = name:
      ai.app.mkAiApp {
        inherit name;
        supportedPools = [poolName];
        transformers.markdown = ai.transformers.claude;
        defaults.package = pkgs.hello;
        options =
          {
            _observedPool = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
              internal = true;
            };
          }
          // lib.optionalAttrs (builtins.hasAttr poolName customPoolOptions) {
            ${poolName} = customPoolOptions.${poolName};
          };
        hm.config = args: {
          ai.${name}._observedPool = args.${mergedArg};
        };
      };
    evaluated = lib.evalModules {
      modules = [
        ai.sharedOptions
        hmStubs
        (ai.app.hmTransform (mkRecord runtimeA))
        (ai.app.hmTransform (mkRecord runtimeB))
        {
          config.ai = {
            ${poolName} = {
              inherited = rootValue;
              removed = rootValue;
              replaced = rootValue;
            };
            ${runtimeA} = {
              enable = true;
              ${poolName} = {
                removed = null;
                replaced = runtimeValue;
              };
            };
            ${runtimeB}.enable = true;
          };
        }
      ];
    };
    observedA = evaluated.config.ai.${runtimeA}._observedPool;
    observedB = evaluated.config.ai.${runtimeB}._observedPool;
  in
    !(observedA ? removed)
    && checkRoot observedA.inherited
    && checkRuntime observedA.replaced
    && checkRoot observedB.removed
    && checkRoot observedB.replaced;

  mkServiceServerDef = httpMode: meta: {
    meta =
      {
        defaultPort = 12345;
        modes = {
          http = httpMode;
          stdio = "test-mcp";
        };
        scope = "remote";
        tools = [];
      }
      // meta;
    settingsOptions = {};
    settingsToArgs = _cfg: _mode: [];
    settingsToEnv = _cfg: _mode: {};
  };

  evalService = {
    config ? {},
    name ? "test-mcp",
    serverDef,
  }:
    lib.evalModules {
      modules = [
        {
          options.server = lib.mkOption {
            type = lib.types.submodule (ai.mcpServer.mkServiceModule {
              inherit name serverDef;
              resolvePackage = _: pkgs.hello;
            });
            default = {};
          };
          config.server = config;
        }
      ];
    };
in {inherit ai aiCommon devenvStubs evalService factoryProxyServer hmStubs mkProxyTestRecord mkServiceServerDef mkTest poolMergeContract;}
