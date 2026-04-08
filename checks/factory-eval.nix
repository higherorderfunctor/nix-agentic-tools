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

  # Stub HM option types so mkAiApp's baseline home.file render
  # (introduced when the render pipeline was wired) can write to
  # home.file.* without importing home-manager. Mirrors the
  # hmStubs pattern in checks/module-eval.nix.
  hmStubs = {
    options.home = {
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

  mkTest = name: assertion:
    pkgs.runCommand "factory-test-${name}" {} ''
      ${
        if assertion
        then ''echo "PASS: ${name}" > $out''
        else throw "FAIL: ${name}"
      }
    '';
in {
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
      lib.hasInfix ''applyTo: "**/*.nix,**/*.toml"'' out
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
    let
      result =
        builtins.tryEval
        (lib.evalModules {
          modules = [
            ai.mcpServer.commonSchema
            {config = {package = pkgs.hello;};} # type intentionally omitted — required field
          ];
        }).config.type;
    in
      !result.success
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
      && evaluated.config.ai.instructions == []
      && evaluated.config.ai.skills == {}
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
  factory-mkAiApp-returns-module-function = mkTest "mkAiApp-returns-module-function" (
    let
      module = ai.app.mkAiApp {
        name = "testapp";
        transformers.markdown = ai.transformers.claude;
        defaults = {
          package = pkgs.hello;
          outputPath = ".config/test/CONFIG.md";
        };
      };
    in
      builtins.isFunction module
  );

  factory-mkAiApp-builds-option-tree = mkTest "mkAiApp-builds-option-tree" (
    let
      module = ai.app.mkAiApp {
        name = "testapp";
        transformers.markdown = ai.transformers.claude;
        defaults = {
          package = pkgs.hello;
          outputPath = ".config/test/CONFIG.md";
        };
      };
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
      module = ai.app.mkAiApp {
        name = "testapp";
        transformers.markdown = ai.transformers.claude;
        defaults = {package = pkgs.hello;};
        options = {
          turboMode = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        };
      };
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
      module = ai.app.mkAiApp {
        name = "testapp";
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
}
