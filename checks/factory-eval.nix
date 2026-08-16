# Golden tests for lib.ai.* factory primitives.
#
# Each test is a Nix assertion wrapped in a runCommand. The runCommand
# only produces $out if the assertion passes; otherwise the throw
# propagates up and `nix flake check` reports the failure.
#
# Mirrors the harness pattern from checks/fragments-eval.nix.
{
  lib,
  pkgs,
  ...
}: let
  ai = import ../lib/ai {inherit lib;};
  aiCommon = import ../lib/ai/ai-common.nix {inherit lib;};

  # Stub HM option types so mkAiApp's baseline home.file render
  # (introduced when the render pipeline was wired) can write to
  # home.file.* without importing home-manager. Mirrors the
  # hmStubs pattern in checks/module-eval.nix.
  hmStubs = {
    options = {
      # The HM transform always defines this for the hm backend (it is
      # `{}` when no server sets `proxy.enable`), because the condition
      # cannot read `config` without recursing. See mkBackendTransform.
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
      };
    };
  };

  mkTest = name: assertion:
    pkgs.runCommand "factory-test-${name}" {} ''
      ${
        if assertion
        then ''echo "PASS: ${name}" > $out''
        else throw "FAIL: ${name}"
      }
    '';

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
in {
  # ── Normalized keyed-pool replacement and negation ──────────────
  factory-pool-agents-negation = mkTest "pool-agents-negation" (poolMergeContract {
    poolName = "agents";
    rootValue = {
      description = "root";
      instructions = "root";
      tools = ["Read"];
    };
    runtimeValue = {
      description = "runtime";
      instructions = "runtime";
    };
    checkRoot = value:
      value.description == "root" && value.tools == ["Read"];
    checkRuntime = value:
      value.description == "runtime" && value.tools == null;
  });
  factory-pool-environmentVariables-negation = mkTest "pool-environmentVariables-negation" (poolMergeContract {
    poolName = "environmentVariables";
    rootValue = "root";
    runtimeValue = "runtime";
    checkRoot = value: value == "root";
    checkRuntime = value: value == "runtime";
  });
  factory-pool-lspServers-negation = mkTest "pool-lspServers-negation" (poolMergeContract {
    poolName = "lspServers";
    rootValue = {
      command = "root-lsp";
      args = ["--root-only"];
    };
    runtimeValue.command = "runtime-lsp";
    checkRoot = value:
      value.command == "root-lsp" && value.args == ["--root-only"];
    checkRuntime = value:
      value.command == "runtime-lsp" && value.args == ["--stdio"];
  });
  factory-pool-mcpServers-negation = mkTest "pool-mcpServers-negation" (poolMergeContract {
    poolName = "mcpServers";
    rootValue = {
      type = "stdio";
      command = "root-mcp";
      args = ["--root-only"];
    };
    runtimeValue = {
      type = "stdio";
      command = "runtime-mcp";
    };
    checkRoot = value:
      value.command == "root-mcp" && value.args == ["--root-only"];
    checkRuntime = value:
      value.command == "runtime-mcp" && value.args == [];
  });
  factory-pool-rules-negation = mkTest "pool-rules-negation" (poolMergeContract {
    poolName = "rules";
    rootValue = {
      text = "root";
      matcher = ["**/*.root"];
    };
    runtimeValue.text = "runtime";
    checkRoot = value:
      value.text == "root" && value.matcher == ["**/*.root"];
    checkRuntime = value:
      value.text == "runtime" && value.matcher == null;
  });
  factory-pool-skills-negation = mkTest "pool-skills-negation" (poolMergeContract {
    poolName = "skills";
    rootValue = ./fixtures/claude-agents;
    runtimeValue = ./fixtures/kiro-steering;
    checkRoot = value: value == ./fixtures/claude-agents;
    checkRuntime = value: value == ./fixtures/kiro-steering;
  });

  # ── Transformer shape tests ─────────────────────────────────────
  factory-transformer-claude-empty = mkTest "transformer-claude-empty" (
    ai.transformers.claude.render {text = "";} == ""
  );

  factory-transformer-claude-plain-text = mkTest "transformer-claude-plain-text" (
    ai.transformers.claude.render {text = "hello world";} == "hello world"
  );

  factory-transformer-claude-with-frontmatter = mkTest "transformer-claude-with-frontmatter" (
    let
      out = ai.transformers.claude.render {
        description = "Test rule";
        paths = ["**/*.nix"];
        text = "body content";
      };
    in
      lib.hasPrefix "---\n" out && lib.hasInfix "description: Test rule" out
  );

  factory-transformer-copilot-applyto = mkTest "transformer-copilot-applyto" (
    let
      out = ai.transformers.copilot.render {
        description = "Nix rule";
        paths = [
          "**/*.nix"
          "**/*.toml"
        ];
        text = "body";
      };
    in
      out
      == "---\napplyTo: \"**/*.nix,**/*.toml\"\n---\n\nbody"
  );

  factory-transformer-kiro-always = mkTest "transformer-kiro-always" (
    let
      out = ai.transformers.kiro.render {
        inclusion = "always";
        paths = ["**/*.nix"];
        text = "body";
      };
    in
      lib.hasInfix "inclusion: always" out && !(lib.hasInfix "fileMatchPattern:" out)
  );

  factory-transformer-kiro-auto = mkTest "transformer-kiro-auto" (
    let
      out = ai.transformers.kiro.render {
        description = "Semantic Kiro guidance";
        inclusion = "auto";
        name = "semantic-guidance";
        paths = ["**/*.nix"];
        text = "body";
      };
    in
      lib.hasInfix "description: Semantic Kiro guidance" out
      && lib.hasInfix "inclusion: auto" out
      && lib.hasInfix "name: semantic-guidance" out
      && !(lib.hasInfix "fileMatchPattern:" out)
  );

  factory-transformer-kiro-fileMatch = mkTest "transformer-kiro-fileMatch" (
    let
      out = ai.transformers.kiro.render {
        description = "Kiro rule";
        paths = ["**/*.nix"];
        text = "body";
      };
    in
      lib.hasInfix "inclusion: fileMatch" out && lib.hasInfix "fileMatchPattern:" out
  );

  factory-transformer-kiro-manual = mkTest "transformer-kiro-manual" (
    let
      out = ai.transformers.kiro.render {
        inclusion = "manual";
        name = "on-demand";
        text = "body";
      };
    in
      lib.hasInfix "inclusion: manual" out
      && lib.hasInfix "name: on-demand" out
      && !(lib.hasInfix "fileMatchPattern:" out)
  );

  factory-transformer-kiro-path-text = mkTest "transformer-kiro-path-text" (
    let
      out = ai.transformers.kiro.render {
        inclusion = "manual";
        name = "path-backed";
        text = ./fixtures/kiro-steering/alpha.md;
      };
    in
      lib.hasInfix "inclusion: manual" out
      && lib.hasInfix "Alpha steering body." out
  );

  factory-transformer-kiro-validates-required-fields = mkTest "transformer-kiro-validates-required-fields" (
    let
      succeeds = fragment:
        (builtins.tryEval (builtins.deepSeq (ai.transformers.kiro.render fragment) true)).success;
    in
      !(succeeds {
        inclusion = "auto";
        name = "missing-description";
        text = "body";
      })
      && !(succeeds {
        description = "Missing name";
        inclusion = "auto";
        text = "body";
      })
      && !(succeeds {
        inclusion = "fileMatch";
        text = "body";
      })
  );

  factory-transformer-agentsmd-no-frontmatter = mkTest "transformer-agentsmd-no-frontmatter" (
    let
      out = ai.transformers.agentsmd.render {
        description = "ignored";
        paths = ["ignored"];
        text = "body only";
      };
    in
      out == "body only"
  );

  # ── mcpServer.commonSchema tests ────────────────────────────────
  factory-mcpServer-commonSchema-minimal = mkTest "mcpServer-commonSchema-minimal" (
    let
      evaluated = lib.evalModules {
        modules = [
          ai.mcpServer.commonSchema
          {
            config = {
              type = "stdio";
              package = pkgs.hello;
              command = "hello";
              args = ["--version"];
            };
          }
        ];
      };
    in
      evaluated.config.type
      == "stdio"
      && evaluated.config.command == "hello"
  );

  factory-mcpServer-commonSchema-type-enforced = mkTest "mcpServer-commonSchema-type-enforced" (
    # `type` is nullable in the new schema (renderServer infers from
    # which other fields are set), but the enum constraint still
    # applies when a value is provided. Setting an invalid type must
    # fail evaluation.
    let
      result =
        builtins.tryEval
        (lib.evalModules {
          modules = [
            ai.mcpServer.commonSchema
            {config.type = "BOGUS_TRANSPORT";}
          ];
        }).config.type;
    in
      !result.success
  );

  # Bridge mode honors service.host in the shared mcp-proxy wrapper, so it
  # needs no per-server metadata declaration and still accepts overrides.
  factory-mcpServer-service-host-bridge-accepted = mkTest "mcpServer-service-host-bridge-accepted" (
    let
      result = evalService {
        config.service.host = "127.0.0.2";
        serverDef = mkServiceServerDef "bridge" {};
      };
    in
      result.config.server.service.host == "127.0.0.2"
  );

  # A native mode must state its audit result. This is the structural guard
  # that turns a future bridge -> native switch into an evaluation failure.
  factory-mcpServer-service-host-native-audit-required = mkTest "mcpServer-service-host-native-audit-required" (
    let
      attempt = builtins.tryEval (builtins.deepSeq
        (evalService {
          serverDef = mkServiceServerDef "test-mcp --http" {};
        }).config.server.service.host
        true);
    in
      !attempt.success
  );

  factory-mcpServer-service-host-native-supported = mkTest "mcpServer-service-host-native-supported" (
    let
      result = evalService {
        config.service.host = "127.0.0.2";
        serverDef = mkServiceServerDef "test-mcp --http" {honorsServiceHost = true;};
      };
    in
      result.config.server.service.host == "127.0.0.2"
  );

  # Any concrete value is rejected for an unsupported native mode, including
  # the old apparent default. Leaving it unset is the only accepted shape.
  factory-mcpServer-service-host-native-unsupported-rejected = mkTest "mcpServer-service-host-native-unsupported-rejected" (
    let
      attempt = builtins.tryEval (builtins.deepSeq
        (evalService {
          config.service.host = "127.0.0.1";
          serverDef = mkServiceServerDef "test-mcp --http" {honorsServiceHost = false;};
        }).config.server.service.host
        true);
    in
      !attempt.success
  );

  # ── mcpServer.mkMcpServer tests ─────────────────────────────────
  factory-mcpServer-mkMcpServer-returns-function = mkTest "mkMcpServer-returns-function" (
    let
      factory = ai.mcpServer.mkMcpServer {
        name = "test";
        defaults = {package = pkgs.hello;};
      };
    in
      builtins.isFunction factory
  );

  factory-mcpServer-mkMcpServer-builds-instance = mkTest "mkMcpServer-builds-instance" (
    let
      factory = ai.mcpServer.mkMcpServer {
        name = "test";
        defaults = {
          package = pkgs.hello;
          type = "stdio";
          command = "hello";
        };
      };
      instance = factory {args = ["--version"];};
    in
      instance.type
      == "stdio"
      && instance.command == "hello"
      && instance.args == ["--version"]
  );

  factory-mcpServer-mkMcpServer-custom-options = mkTest "mkMcpServer-custom-options" (
    let
      factory = ai.mcpServer.mkMcpServer {
        name = "weird";
        defaults = {
          package = pkgs.hello;
          type = "stdio";
          command = "hello";
        };
        options = {
          turboMode = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        };
      };
      instance = factory {turboMode = true;};
    in
      instance.turboMode or false
  );

  factory-mcpServer-mkMcpServer-list-merge = mkTest "mkMcpServer-list-merge" (
    let
      factory = ai.mcpServer.mkMcpServer {
        name = "test";
        defaults = {
          package = pkgs.hello;
          type = "stdio";
          command = "hello";
          args = ["--from-defaults"];
        };
      };
      instance = factory {args = ["--from-consumer"];};
    in
      # With module-system merge on listOf: ["--from-defaults" "--from-consumer"]
      # Both values must be present (concatenation semantics).
      builtins.elem "--from-defaults" instance.args
      && builtins.elem "--from-consumer" instance.args
  );

  # ── loadServer per-package relocation tests (A5) ────────────────
  factory-loadServer-github-mcp-from-package-dir = mkTest "loadServer-github-mcp-from-package-dir" (
    let
      mcpLib = import ../lib/mcp.nix {inherit lib;};
      serverDef = mcpLib.loadServer "github-mcp";
    in
      serverDef ? settingsOptions
      && serverDef.settingsOptions ? credentials
  );

  factory-loadServer-gitlab-mcp-from-package-dir = mkTest "loadServer-gitlab-mcp-from-package-dir" (
    let
      mcpLib = import ../lib/mcp.nix {inherit lib;};
      serverDef = mcpLib.loadServer "gitlab-mcp";
    in
      serverDef ? settingsOptions
      && serverDef.settingsOptions ? pat
  );

  factory-loadServer-kagi-mcp-from-package-dir = mkTest "loadServer-kagi-mcp-from-package-dir" (
    let
      mcpLib = import ../lib/mcp.nix {inherit lib;};
      serverDef = mcpLib.loadServer "kagi-mcp";
    in
      serverDef ? settingsOptions
      && serverDef.settingsOptions ? credentials
  );

  factory-github-mcp-has-package-module = mkTest "github-mcp-has-package-module" (
    builtins.pathExists ../packages/github-mcp/modules/mcp-server.nix
  );

  factory-gitlab-mcp-has-package-module = mkTest "gitlab-mcp-has-package-module" (
    builtins.pathExists ../packages/gitlab-mcp/modules/mcp-server.nix
  );

  # ── sharedOptions tests ─────────────────────────────────────────
  factory-sharedOptions-empty-defaults = mkTest "sharedOptions-empty-defaults" (
    let
      evaluated = lib.evalModules {
        modules = [
          ai.sharedOptions
          {config = {};}
        ];
      };
    in
      evaluated.config.ai.mcpServers
      == {}
      && evaluated.config.ai.rules == {}
      && evaluated.config.ai.settings.reasoningEffort == null
      && evaluated.config.ai.skills == {}
  );

  factory-sharedOptions-reasoning-effort-is-portable-intersection = mkTest "sharedOptions-reasoning-effort-is-portable-intersection" (
    let
      accepts = value:
        (builtins.tryEval
          (lib.evalModules {
            modules = [
              ai.sharedOptions
              {config.ai.settings.reasoningEffort = value;}
            ];
          }).config.ai.settings.reasoningEffort)
        .success;
    in
      accepts "low"
      && accepts "medium"
      && accepts "high"
      && accepts "xhigh"
      && !(accepts "max")
      && !(accepts "ultra")
  );

  factory-sharedOptions-accepts-mcpServer-entry = mkTest "sharedOptions-accepts-mcpServer-entry" (
    let
      evaluated = lib.evalModules {
        modules = [
          ai.sharedOptions
          {
            config.ai.mcpServers.test = {
              type = "stdio";
              package = pkgs.hello;
              command = "hello";
            };
          }
        ];
      };
    in
      evaluated.config.ai.mcpServers.test.type == "stdio"
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
        hm = {
          config = {mergedServers, ...}: {
            ai.testapp._mergedServerCount = builtins.length (builtins.attrNames mergedServers);
          };
        };
      };
      module = ai.app.hmTransform record;
      evaluated = lib.evalModules {
        modules = [
          (import ../lib/ai/sharedOptions.nix)
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
      # devenv stub: `files` option instead of `home.file`
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
        };
      };
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
}
