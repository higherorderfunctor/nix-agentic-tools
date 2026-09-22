# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiStubs evalDevenv evalHm hmLib mkTest mkWrapperGrepTest;
  inherit (import ../../chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
  inherit (import ../../kiro-cli/checks/helpers.nix {inherit lib pkgs harness;}) kiroSteeringFiles;
in {
  checks = {
    # ── Semble convenience integration ───────────────────────────────
    module-semble-default-disabled = mkTest "semble-default-disabled" (
      let
        hm = evalHm {};
        devenv = evalDevenv {};
        clean = evaluated:
          !evaluated.config.ai.programs.semble.enable
          && evaluated.config.ai.programs.semble.mcp.enable == null
          && !(evaluated.config.ai.claude.mcpServers ? semble)
          && !(evaluated.config.ai.codex.agents ? semble-search)
          && !(evaluated.config.ai.kiro.agents ? semble-search);
      in
        clean hm
        && clean devenv
        && hm.config.home.packages == []
        && devenv.config.packages == []
    );

    module-semble-codex-sandbox-cache-parity = mkTest "semble-codex-sandbox-cache-parity" (
      let
        config = {
          ai.codex = {
            enable = true;
            nativeSettings = {
              sandbox_mode = "workspace-write";
              sandbox_workspace_write.writable_roots = ["/consumer-cache"];
            };
            programs.semble.enable = true;
          };
        };
        hasWrappedSemble = packages:
          builtins.any
          (drv:
            lib.hasSuffix "${lib.getName aiStubs.semble}-wrapped" (
              builtins.baseNameOf drv
            ))
          packages;
        hmEval = evalHm config;
        hm = hmEval.config;
        devenv = (evalDevenv config).config;
        readOnly =
          (evalDevenv {
            ai.codex.nativeSettings.sandbox_mode = "read-only";
            ai.codex.programs.semble.enable = true;
          }).config;
        noCodex =
          (evalDevenv {
            ai.codex.nativeSettings.sandbox_mode = "workspace-write";
            ai.claude.programs.semble.enable = true;
          }).config;
        profileConfig.ai.codex = {
          enable = true;
          nativeSettings.default_permissions = "project-edit";
          programs.semble.enable = true;
        };
        profileOnly = (evalDevenv profileConfig).config;
        profileDenied =
          (evalDevenv (lib.recursiveUpdate profileConfig {
            ai.codex.nativeSettings.permissions.project-edit.filesystem."/tmp/devenv-state/semble-cache" = "deny";
          })).config;
      in
        builtins.all
        (root: builtins.elem root (hmCodexSettings hmEval).sandbox_workspace_write.writable_roots)
        ["/consumer-cache" "/home/test/.cache/nix" "/home/test/.cache/semble"]
        && builtins.length (hmCodexSettings hmEval).sandbox_workspace_write.writable_roots == 3
        && builtins.all
        (root: builtins.elem root devenv.files.".codex/config.toml".source.value.sandbox_workspace_write.writable_roots)
        ["/consumer-cache" "/tmp/devenv-root/.git" "/tmp/devenv-state/semble-cache"]
        # Both backends make their selected cache authoritative through the
        # launcher wrapper. Never through the surrounding shell: that would
        # export the value to the user's session and everything else in it.
        && hasWrappedSemble hm.home.packages
        && hasWrappedSemble devenv.packages
        && readOnly.ai.codex.nativeSettings.sandbox_workspace_write == null
        && noCodex.ai.codex.nativeSettings.sandbox_workspace_write == null
        && profileOnly.ai.codex.nativeSettings.sandbox_workspace_write == null
        && profileOnly.files.".codex/config.toml".source.value.permissions.project-edit.filesystem."/tmp/devenv-state/semble-cache" == "write"
        && profileDenied.files.".codex/config.toml".source.value.permissions.project-edit.filesystem."/tmp/devenv-state/semble-cache" == "deny"
        && builtins.all (assertion: assertion.assertion) profileOnly.assertions
        && builtins.all (assertion: assertion.assertion) profileDenied.assertions
    );

    # CONTENT coverage for semble's relocated cache. The parity test above can
    # only assert the derivation NAME, which symlinkJoin emits whether or not
    # the wrapper actually carries anything — so on its own it would pass a
    # wrapper that sets nothing at all. This greps every entry point, because
    # `semble` and `semble-mcp` disagreeing about the cache location is the
    # specific failure the single-wrapper design exists to prevent.
    module-semble-devenv-cache-in-every-entry-point = let
      semblePackage =
        builtins.head
        (evalDevenv {
          ai.codex.programs.semble.enable = true;
        })
      .config
      .packages;
    in
      pkgs.runCommand "module-test-semble-devenv-cache-in-every-entry-point" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        pkg=${semblePackage}
        found=0
        for bin in "$pkg"/bin/*; do
          found=$((found + 1))
          grep -qF -- 'SEMBLE_CACHE_LOCATION' "$bin" \
            || { echo "FAIL: $bin does not carry SEMBLE_CACHE_LOCATION" >&2; exit 1; }
          grep -qF -- '/semble-cache' "$bin" \
            || { echo "FAIL: $bin does not carry the relocated cache path" >&2; exit 1; }
        done
        # An empty bin/ would pass the loop vacuously.
        [ "$found" -gt 0 ] || { echo "FAIL: wrapper exposes no entry points" >&2; exit 1; }
        echo PASS > "$out"
      '';

    module-semble-umbrella-fanout = mkTest "semble-umbrella-fanout" (
      let
        evaluated = evalHm {ai.programs.semble.enable = true;};
        cfg = evaluated.config;
      in
        builtins.length cfg.home.packages
        == 1
        && lib.all (runtime: cfg.ai.${runtime}.mcpServers ? semble) ["claude" "codex" "kiro"]
        && lib.all (runtime: cfg.ai.${runtime}.rules == {}) ["claude" "codex" "kiro"]
        && lib.all (runtime: !(cfg.ai.${runtime}.agents ? semble-search)) ["claude" "codex" "kiro"]
        && !(cfg.ai.copilot.mcpServers ? semble)
        && !(cfg.ai.copilot.agents ? semble-search)
        && cfg.ai.copilot.rules == {}
    );

    # End-to-end regression guard for the defect that motivated typing this
    # surface: Semble's agent file shipped WITHOUT `name`, so Kiro's Rust CLI
    # rejected it with "missing field name" on every invocation and the agent
    # never loaded, while the Node/ACP parser (which treats `name` as optional)
    # kept working and hid it. With Kiro actually enabled the file must carry
    # `name` equal to its attr key — which is also its filename stem.
    module-semble-kiro-agent-emits-name = mkTest "semble-kiro-agent-emits-name" (
      let
        cfg =
          (evalHm {
            ai.programs.semble.subagent.enable = true;
            ai.kiro.enable = true;
          }).config;
        emitted =
          builtins.fromJSON
          cfg.home.file.".kiro/agents/semble-search.json".text;
      in
        emitted.name
        == "semble-search"
        && emitted.tools == ["shell" "read"]
        && emitted ? description
        && !(lib.hasPrefix builtins.storeDir emitted.prompt)
    );

    module-semble-feature-enable-overrides = mkTest "semble-feature-enable-overrides" (
      let
        onlyMcp = (evalDevenv {ai.programs.semble.mcp.enable = true;}).config;
        noMcp =
          (evalDevenv {
            ai.programs.semble = {
              enable = true;
              mcp.enable = false;
            };
          }).config;
        onlyInstructions =
          (evalDevenv {
            ai.programs.semble.instructions.cli.enable = true;
          }).config;
        onlySubagent =
          (evalDevenv {
            ai.programs.semble.subagent.enable = true;
          }).config;
      in
        builtins.length onlyMcp.packages
        == 1
        && onlyMcp.ai.claude.mcpServers ? semble
        && onlyMcp.ai.claude.rules == {}
        && !(onlyMcp.ai.claude.agents ? semble-search)
        && !(noMcp.ai.claude.mcpServers ? semble)
        && noMcp.ai.claude.rules == {}
        && !(noMcp.ai.claude.agents ? semble-search)
        && builtins.length onlyInstructions.packages == 1
        && onlyInstructions.ai.claude.rules ? semble
        && !(onlyInstructions.ai.claude.agents ? semble-search)
        && !(onlyInstructions.ai.claude.mcpServers ? semble)
        && builtins.length onlySubagent.packages == 1
        && onlySubagent.ai.claude.agents ? semble-search
        && onlySubagent.ai.claude.rules == {}
        && !(onlySubagent.ai.claude.mcpServers ? semble)
    );

    module-semble-program-overrides = mkTest "semble-program-overrides" (
      let
        top =
          (evalHm {
            ai = {
              programs.semble = {
                enable = true;
                mcp = {
                  content = "docs";
                  enable = true;
                };
              };
              claude.programs.semble.enable = false;
              kiro.programs.semble.enable = false;
            };
          }).config;
        perFeature =
          (evalDevenv {
            ai = {
              programs.semble.mcp.content = "docs";
              claude.programs.semble.instructions.cli.enable = true;
              codex.programs.semble.subagent.enable = true;
              kiro.programs.semble.mcp = {
                content = "config";
                enable = true;
              };
            };
          }).config;
        runtimeFeatureWins =
          (evalHm {
            ai = {
              programs.semble.mcp.enable = true;
              codex.programs.semble = {
                enable = false;
                mcp.enable = true;
              };
            };
          }).config;
      in
        top.ai.codex.mcpServers ? semble
        && top.ai.codex.mcpServers.semble.args == ["--content" "docs"]
        && !(top.ai.codex.agents ? semble-search)
        && top.ai.codex.rules == {}
        && !(top.ai.claude.mcpServers ? semble)
        && !(top.ai.kiro.agents ? semble-search)
        && perFeature.ai.kiro.mcpServers ? semble
        && perFeature.ai.kiro.mcpServers.semble.args == ["--content" "config"]
        && !(perFeature.ai.claude.mcpServers ? semble)
        && perFeature.ai.claude.rules ? semble
        && perFeature.ai.codex.rules == {}
        && perFeature.ai.codex.agents ? semble-search
        && !(perFeature.ai.kiro.agents ? semble-search)
        && runtimeFeatureWins.ai.codex.mcpServers ? semble
        && !(runtimeFeatureWins.ai.codex.rules ? semble)
    );

    module-semble-extra-grammars-and-cache-hooks = mkTest "semble-extra-grammars-and-cache-hooks" (
      let
        grammarConfig = {
          ai.codex.programs.semble = {
            enable = true;
            grammars = with pkgs.tree-sitter-grammars; [
              tree-sitter-awk
              tree-sitter-jq
            ];
            mcp.pathMappings = [
              {
                content = "config";
                language = "json";
                patterns = ["flake.lock"];
              }
            ];
          };
        };
        hm = (evalHm grammarConfig).config;
        devenv = (evalDevenv grammarConfig).config;
        hmPackage = builtins.head hm.home.packages;
      in
        hmPackage.sembleExtraGrammarLanguages
        == ["awk" "jq"]
        && hmPackage.semblePathMappings == grammarConfig.ai.codex.programs.semble.mcp.pathMappings
        && hmPackage.passthru.updateFlakeInput == "llm-agents"
        && hm.home.activation ? sembleCacheGuard
        && lib.hasInfix "semble-cache-guard" hm.home.activation.sembleCacheGuard.text
        && lib.hasInfix "semble-cache-guard" devenv.enterShell
        && lib.hasSuffix "/bin/semble-mcp" devenv.ai.codex.mcpServers.semble.command
    );

    module-semble-runtime-package-variants = let
      evaluated =
        (evalHm {
          ai = {
            programs.semble = {
              enable = true;
              instructions.cli.enable = true;
            };
            codex.programs.semble.grammars = [pkgs.tree-sitter-grammars.tree-sitter-awk];
            kiro.programs.semble.grammars = [pkgs.tree-sitter-grammars.tree-sitter-jq];
          };
        }).config;
      installedPackage = builtins.head evaluated.home.packages;
      cacheByRuntime = installedPackage.sembleCacheLocations;
      cacheLocations = lib.attrValues cacheByRuntime;
      runtimePackages = installedPackage.sembleRuntimePackages;
    in
      assert builtins.length evaluated.home.packages == 1;
      assert builtins.length (lib.unique cacheLocations) == 3;
      assert lib.hasInfix "semble-claude search" evaluated.ai.claude.rules.semble.text;
      assert lib.hasInfix "semble-codex search" evaluated.ai.codex.rules.semble.text;
      assert lib.hasInfix "semble-kiro search" evaluated.ai.kiro.rules.semble.text;
      assert runtimePackages.claude != runtimePackages.codex;
      assert runtimePackages.codex != runtimePackages.kiro;
        pkgs.runCommand "module-test-semble-runtime-package-variants" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          test -x ${installedPackage}/bin/semble
          test -x ${installedPackage}/bin/semble-claude
          test -x ${installedPackage}/bin/semble-codex
          test -x ${installedPackage}/bin/semble-kiro
          test "$(${pkgs.coreutils}/bin/readlink -f ${installedPackage}/bin/semble-claude)" \
            != "$(${pkgs.coreutils}/bin/readlink -f ${installedPackage}/bin/semble-codex)"
          test "$(${pkgs.coreutils}/bin/readlink -f ${installedPackage}/bin/semble-codex)" \
            != "$(${pkgs.coreutils}/bin/readlink -f ${installedPackage}/bin/semble-kiro)"
          ${pkgs.gnugrep}/bin/grep -F ${lib.escapeShellArg cacheByRuntime.claude} ${runtimePackages.claude}/bin/semble
          ${pkgs.gnugrep}/bin/grep -F ${lib.escapeShellArg cacheByRuntime.codex} ${runtimePackages.codex}/bin/semble
          ${pkgs.gnugrep}/bin/grep -F ${lib.escapeShellArg cacheByRuntime.kiro} ${runtimePackages.kiro}/bin/semble
          ${pkgs.coreutils}/bin/touch "$out"
        '';

    module-semble-path-mapping-validation = mkTest "semble-path-mapping-validation" (
      let
        empty =
          (evalDevenv {
            ai.programs.semble = {
              enable = true;
              mcp.pathMappings = [
                {
                  content = "code";
                  language = "";
                  patterns = [];
                }
              ];
            };
          }).config;
        duplicate =
          (evalHm {
            ai.programs.semble = {
              enable = true;
              mcp.pathMappings = [
                {
                  content = "code";
                  language = "bash";
                  patterns = [".envrc"];
                }
                {
                  content = "config";
                  language = "json";
                  patterns = [".envrc"];
                }
              ];
            };
          }).config;
      in
        builtins.any (assertion: !assertion.assertion && lib.hasInfix "non-empty language" assertion.message) empty.assertions
        && builtins.any (assertion: !assertion.assertion && lib.hasInfix "patterns must be unique" assertion.message) duplicate.assertions
    );

    module-semble-extra-grammars-load = let
      customizePackage = import ../lib/withGrammars.nix {inherit lib pkgs;};
      pathMappings = [
        {
          content = "code";
          language = "bash";
          patterns = [".envrc" "checks/hooks/pre-edit"];
        }
        {
          content = "config";
          language = "gitignore";
          patterns = [".gitignore" ".sembleignore"];
        }
        {
          content = "config";
          language = "json";
          patterns = ["flake.lock"];
        }
        {
          content = "docs";
          language = "markdown";
          patterns = ["*.fixture.py" "*.md.fixture"];
        }
      ];
      sembleWithGrammars =
        customizePackage pkgs.ai.semble (with pkgs.tree-sitter-grammars; [
          tree-sitter-awk
          tree-sitter-jq
        ])
        pathMappings;
    in
      assert sembleWithGrammars.passthru.updateFlakeInput == "llm-agents";
        pkgs.runCommand "module-test-semble-extra-grammars-load" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          # Reuse the wrapped entry point's interpreter and complete Python path,
          # replacing only its CLI dispatch tail with this parser smoke test.
          ${pkgs.coreutils}/bin/mkdir -p repo/checks/hooks repo/docs
          ${pkgs.coreutils}/bin/touch \
            repo/.envrc \
            repo/.gitignore \
            repo/.sembleignore \
            repo/checks/hooks/pre-edit \
            repo/docs/example.fixture.py \
            repo/docs/example.md.fixture \
            repo/flake.lock
          ${pkgs.coreutils}/bin/head -n 3 ${sembleWithGrammars}/bin/.semble-wrapped > test-grammars.py
          ${pkgs.coreutils}/bin/cat >> test-grammars.py <<'PY'
          import json
          from pathlib import Path
          from types import SimpleNamespace

          from semble.cache import _metadata_matches
          from semble.chunking.core import _cached_get_parser
          from semble.index.file_walker import walk_files
          from semble.index.files import detect_language, get_extensions
          from semble.index.index import SembleIndex
          from semble.path_mappings import CUSTOMIZATION_FINGERPRINT
          from semble.types import ContentType

          samples = {
              "awk": b"BEGIN { print 1 }",
              "jq": b".foo | length",
          }
          for language, source in samples.items():
              parser = _cached_get_parser(language)
              assert parser is not None, language
              assert parser.parse(source).root_node.type == "program", language

          root = Path("repo").resolve()
          expected = {
              ".envrc": "bash",
              ".gitignore": "gitignore",
              ".sembleignore": "gitignore",
              "checks/hooks/pre-edit": "bash",
              "docs/example.fixture.py": "markdown",
              "docs/example.md.fixture": "markdown",
              "flake.lock": "json",
          }
          for relative, language in expected.items():
              assert detect_language(root / relative, root) == language, relative
          assert detect_language(root / "ordinary.py", root) == "python"

          def walked(content: str) -> set[str]:
              content_type = ContentType(content)
              return {
                  path.relative_to(root).as_posix()
                  for path in walk_files(
                      root,
                      get_extensions((content_type,)),
                      content=(content,),
                  )
              }

          assert walked("code") == {".envrc", "checks/hooks/pre-edit"}
          assert walked("docs") == {"docs/example.fixture.py", "docs/example.md.fixture"}
          assert walked("config") == {".gitignore", ".sembleignore", "flake.lock"}
          assert {
              path.relative_to(root).as_posix()
              for path in walk_files(root, [".py"])
          } == {"docs/example.fixture.py"}

          class EmptyIndex:
              def save(self, path: Path) -> None:
                  path.write_bytes(b"")

          persisted = Path("persisted")
          fake_index = SimpleNamespace(
              _bm25_index=EmptyIndex(),
              _semantic_index=EmptyIndex(),
              _root=root,
              _model_path="test-model",
              _content=(ContentType.CODE,),
              _manifest={},
              chunks=[],
          )
          SembleIndex.save(fake_index, persisted)
          metadata = json.loads((persisted / "metadata.json").read_text())
          assert metadata["nix_customization"] == CUSTOMIZATION_FINGERPRINT
          assert _metadata_matches(metadata, "test-model", (ContentType.CODE,))
          metadata["nix_customization"] = "different-package"
          assert not _metadata_matches(metadata, "test-model", (ContentType.CODE,))
          PY
          ${pkgs.coreutils}/bin/chmod +x test-grammars.py
          ./test-grammars.py
          ${pkgs.coreutils}/bin/touch "$out"
        '';

    module-semble-cache-hooks-inert-when-disabled = mkTest "semble-cache-hooks-inert-when-disabled" (
      let
        hm = (evalHm {}).config;
        devenv = (evalDevenv {}).config;
      in
        !(hm.home.activation ? sembleCacheGuard)
        && devenv.enterShell == ""
    );

    module-semble-hm-cache-wrapper = let
      package =
        builtins.head
        (evalHm {
          ai.codex.programs.semble = {
            enable = true;
            package = pkgs.writeShellScriptBin "semble" ''
              set -euETo pipefail
              shopt -s inherit_errexit 2>/dev/null || :
              exec true
            '';
          };
        }).config.home.packages;
    in
      mkWrapperGrepTest {
        name = "semble-hm-cache-wrapper";
        inherit package;
        bin = "semble";
        needles = [
          "SEMBLE_CACHE_LOCATION"
          "/home/test/.cache/semble"
        ];
      };

    module-semble-cache-guard-runtime = let
      cacheHome = "/build/semble-cache-guard-test";
      sembleStub = pkgs.writeShellApplication {
        name = "semble";
        bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
        text = ''
          shopt -s inherit_errexit 2>/dev/null || :
          case "$*" in
            "clear index") printf 'clear\n' >> "''${SEMBLE_CACHE_LOCATION:?}/clear-calls" ;;
            *) printf 'unexpected arguments: %s\n' "$*" >&2; exit 1 ;;
          esac
        '';
      };
      activation =
        (evalHm {
          ai.codex.programs.semble = {
            enable = true;
            package = sembleStub;
          };
          xdg.cacheHome = cacheHome;
        }).config.home.activation.sembleCacheGuard.text;
    in
      pkgs.runCommand "module-test-semble-cache-guard-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${activation}
        test "$(${pkgs.coreutils}/bin/wc -l < ${cacheHome}/semble/clear-calls)" -eq 1
        ${pkgs.gnugrep}/bin/grep -Fx ${lib.escapeShellArg "${sembleStub}"} ${cacheHome}/semble/.nix-package

        ${activation}
        test "$(${pkgs.coreutils}/bin/wc -l < ${cacheHome}/semble/clear-calls)" -eq 1
        ${pkgs.coreutils}/bin/touch "$out"
      '';

    module-semble-grammar-validation = mkTest "semble-grammar-validation" (
      let
        missingLanguage = evalHm {
          ai.programs.semble = {
            enable = true;
            grammars = [pkgs.hello];
          };
        };
        duplicateLanguage = evalDevenv {
          ai.programs.semble = {
            enable = true;
            grammars = with pkgs.tree-sitter-grammars; [
              tree-sitter-awk
              tree-sitter-awk
            ];
          };
        };
        failed = evaluated: builtins.any (assertion: !assertion.assertion) evaluated.config.assertions;
      in
        failed missingLanguage && failed duplicateLanguage
    );

    module-semble-mcp-content-and-atomic-replacement = mkTest "semble-mcp-content-and-atomic-replacement" (
      let
        code = (evalHm {ai.programs.semble.mcp.enable = true;}).config.ai.claude.mcpServers.semble;
        docs =
          (evalHm {
            ai.programs.semble = {
              mcp = {
                content = "docs";
                enable = true;
              };
            };
          }).config.ai.claude.mcpServers.semble;
        codeAndDocs =
          (evalHm {
            ai.programs.semble.mcp = {
              content = ["docs" "code"];
              enable = true;
            };
          }).config.ai.claude.mcpServers.semble;
        replaced =
          (evalHm {
            ai.codex.mcpServers.semble = {
              type = "stdio";
              command = "custom-semble";
              args = ["--log-level" "debug"];
            };
            ai.codex.programs.semble.enable = true;
          }).config.ai.codex.mcpServers.semble;
      in
        code.args
        == []
        && lib.hasSuffix "/bin/semble-mcp" code.command
        && docs.args == ["--content" "docs"]
        && codeAndDocs.args == ["--content" "code" "docs"]
        && replaced.args == ["--log-level" "debug"]
        && replaced.command == "custom-semble"
    );

    module-semble-mcp-content-validation = mkTest "semble-mcp-content-validation" (
      let
        assertionsFor = content:
          (evalHm {ai.programs.semble.mcp = {inherit content;};}).config.assertions;
        hasFailure = needle: assertions:
          builtins.any
          (assertion: !assertion.assertion && lib.hasInfix needle assertion.message)
          assertions;
      in
        hasFailure "at least one category" (assertionsFor [])
        && hasFailure "duplicate categories" (assertionsFor ["docs" "docs"])
        && hasFailure ''combine "all"'' (assertionsFor ["all" "code"])
    );

    module-semble-mcp-subagent-wiring = mkTest "semble-mcp-subagent-wiring" (
      let
        mcpSubagent = {
          enable = true;
          interface = "mcp";
        };
        rootVisible =
          (evalHm {
            ai.kiro.programs.semble = {
              enable = true;
              subagent = mcpSubagent;
            };
          }).config;
        isolated =
          (evalHm {
            ai.kiro = {
              enable = true;
              programs.semble = {
                enable = true;
                mcp.rootExposure = false;
                subagent = mcpSubagent;
              };
            };
          }).config;
        claude =
          (evalHm {
            ai.claude.programs.semble = {
              enable = true;
              subagent = mcpSubagent;
            };
          }).config;
        unsupported =
          (evalHm {
            ai.claude.programs.semble = {
              enable = true;
              mcp.rootExposure = false;
              subagent = mcpSubagent;
            };
          }).config;
        missingMcp =
          (evalHm {
            ai.codex.programs.semble = {
              mcp.enable = false;
              subagent = mcpSubagent;
            };
          }).config;
        orphaned =
          (evalHm {
            ai.kiro.programs.semble = {
              enable = true;
              mcp.rootExposure = false;
            };
          }).config;
        failedWith = needle: evaluated:
          builtins.any
          (assertion: !assertion.assertion && lib.hasInfix needle assertion.message)
          evaluated.assertions;
        mcpPrompt = ../mcp-agent-instructions.md;
        rootAgent = rootVisible.ai.kiro.agents.semble-search;
        isolatedAgent = isolated.ai.kiro.agents.semble-search;
        emitted =
          builtins.fromJSON
          (builtins.unsafeDiscardStringContext isolated.home.file.".kiro/agents/semble-search.json".text);
      in
        builtins.attrNames rootVisible.ai.kiro.mcpServers
        == ["semble"]
        && rootAgent.tools == ["@semble"]
        && rootAgent.includeMcpJson == false
        && rootAgent.mcpServers ? semble
        && builtins.attrNames isolated.ai.kiro.mcpServers == []
        && isolatedAgent.tools == ["@semble"]
        && isolatedAgent.includeMcpJson == false
        && isolatedAgent.mcpServers ? semble
        && emitted.tools == ["@semble"]
        && emitted.prompt == builtins.readFile mcpPrompt
        && emitted.includeMcpJson == false
        && emitted.mcpServers ? semble
        && claude.ai.claude.agents.semble-search.tools
        == ["mcp__semble__find_related" "mcp__semble__search"]
        && failedWith "only Kiro" unsupported
        && failedWith "requires the Semble MCP integration" missingMcp
        && failedWith "requires an enabled MCP-backed" orphaned
    );

    module-semble-kiro-acp = let
      evaluated = evalHm {
        ai.kiro = {
          enable = true;
          programs.semble = {
            enable = true;
            mcp.rootExposure = false;
            subagent = {
              enable = true;
              interface = "mcp";
            };
          };
        };
      };
      agentFile = pkgs.writeText "semble-search.json" evaluated.config.home.file.".kiro/agents/semble-search.json".text;
      controlFile = pkgs.writeText "control-search.json" (builtins.toJSON {
        name = "control-search";
        description = "Negative control without an MCP server.";
        prompt = "Do nothing.";
        tools = ["read"];
      });
      invalidFile = pkgs.writeText "invalid-search.json" "{}";
    in
      pkgs.runCommandLocal "module-test-semble-kiro-acp" {nativeBuildInputs = [pkgs.python3];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        export HOME="$TMPDIR/home"
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        export XDG_CACHE_HOME="$TMPDIR/cache"
        export XDG_CONFIG_HOME="$TMPDIR/config"
        export XDG_DATA_HOME="$TMPDIR/data"
        export XDG_STATE_HOME="$TMPDIR/state"
        mkdir -p "$HOME/.kiro/agents" "$TMPDIR/workspace"
        cp ${agentFile} "$HOME/.kiro/agents/semble-search.json"
        cp ${controlFile} "$HOME/.kiro/agents/control-search.json"
        cp ${invalidFile} "$HOME/.kiro/agents/invalid-search.json"

        validate_status=0
        # Drive the unwrapped chat binary that implements `kiro-cli agent
        # validate` directly. The exported Linux package is a buildFHSEnv
        # bubblewrap launcher, and nested user namespaces are not portable across
        # Nix build sandboxes; validation itself needs neither the FHS root nor a
        # login.
        ${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli-chat agent validate \
          --path "$HOME/.kiro/agents/semble-search.json" \
          >"$TMPDIR/validate.stdout" 2>"$TMPDIR/validate.stderr" \
          || validate_status=$?
        test "$validate_status" -eq 0 || {
          cat "$TMPDIR/validate.stderr" >&2
          exit 1
        }
        test ! -s "$TMPDIR/validate.stderr" || {
          cat "$TMPDIR/validate.stderr" >&2
          exit 1
        }

        invalid_status=0
        ${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli-chat agent validate \
          --path "$HOME/.kiro/agents/invalid-search.json" \
          >"$TMPDIR/invalid.stdout" 2>"$TMPDIR/invalid.stderr" \
          || invalid_status=$?
        # Kiro currently exits zero for an invalid file. The stderr assertion is
        # the real validation signal; the status check pins the trap so a future
        # behavior change cannot make this negative control vacuous.
        test "$invalid_status" -eq 0 || {
          cat "$TMPDIR/invalid.stderr" >&2
          exit 1
        }
        grep -Fq 'is invalid: missing field `name`' "$TMPDIR/invalid.stderr" || {
          cat "$TMPDIR/invalid.stderr" >&2
          exit 1
        }

        # Invoke the chat binary directly and omit --agent-engine: this is Kiro's
        # v2 ACP path. The driver sends only initialize and session/new, never a
        # model-bearing session/prompt request.
        python3 ${./semble-kiro-acp.py} \
          ${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli-chat \
          semble-search \
          control-search \
          "$TMPDIR/workspace" \
          >"$TMPDIR/acp.json"
        # Keep the driver's record, do not discard it. Each agent's result
        # carries a `teardown` object saying whether the harness had to SIGKILL
        # the child and how long it waited. Nix prints no log for a build that
        # SUCCEEDS, so a child that quietly stops exiting cleanly would leave no
        # trace anyone reads -- the teardown branch is a pass by design, and a
        # pass with an unread log is indistinguishable from a healthy one.
        cp "$TMPDIR/acp.json" "$out"
      '';

    # The check above SIGKILLs a child that outlives its post-stdin-EOF budget
    # and then reads its exit status. Nothing exercised those branches, so a
    # harness kill was reported as a product crash for five weeks. The real
    # `kiro-cli-chat` cannot be asked to hang, to panic, or to take a
    # third-party signal, so the contract is proved against a fake server that
    # can -- including that an autonomous non-zero exit still FAILS, which is
    # the assertion the fix had to keep.
    module-semble-kiro-acp-teardown = pkgs.runCommandLocal "module-test-semble-kiro-acp-teardown" {nativeBuildInputs = [pkgs.python3];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      python3 ${./teardown-contract.py} ${./semble-kiro-acp.py} ${./fake-acp.py}
      touch "$out"
    '';

    module-semble-package-override-and-named-kiro-rule = mkTest "semble-package-override-and-named-kiro-rule" (
      let
        evaluated = evalDevenv {
          ai.kiro.programs.semble = {
            instructions.cli.enable = true;
            package = pkgs.hello;
          };
        };
        rule = evaluated.config.ai.kiro.rules.semble;
      in
        # devenv relocates the cache, so semble is installed WRAPPED. The
        # wrapper is named after what it wraps, which is what keeps the
        # `package` override observable here rather than hidden behind a
        # fixed derivation name.
        builtins.length evaluated.config.packages
        == 1
        && lib.hasSuffix "hello-wrapped" (
          builtins.baseNameOf (builtins.head evaluated.config.packages)
        )
        && evaluated.config.ai.kiro.mcpServers == {}
        && rule.source == ../cli-instructions.md
    );

    module-semble-rule-text-override-wins = mkTest "semble-rule-text-override-wins" (
      let
        evaluated = evalDevenv {
          ai.kiro.rules.semble.text = "Consumer rule.";
          ai.kiro.programs.semble.instructions.cli.enable = true;
        };
        rule = evaluated.config.ai.kiro.rules.semble;
      in
        rule.text
        == "Consumer rule."
        && rule.source == ../cli-instructions.md
    );

    module-semble-rule-matcher-keeps-packaged-prose = mkTest "semble-rule-matcher-keeps-packaged-prose" (
      let
        evaluated = evalDevenv {
          ai.kiro.rules.semble.matcher = ["src/**"];
          ai.kiro.programs.semble.instructions.cli.enable = true;
        };
        rule = evaluated.config.ai.kiro.rules.semble;
      in
        rule.enable
        && rule.matcher == ["src/**"]
        && rule.source == ../cli-instructions.md
        && lib.hasInfix "Use `semble search`" rule.text
    );

    module-semble-rules-use-native-files = mkTest "semble-rules-use-native-files" (
      let
        nativeConfig = {
          ai = {
            claude.enable = true;
            codex.enable = true;
            kiro.enable = true;
          };
          ai.programs.semble.instructions.cli.enable = true;
        };
        hm = (evalHm nativeConfig).config;
        devenv = (evalDevenv nativeConfig).config;
        hmKiroSteering = kiroSteeringFiles (evalHm nativeConfig);
        devenvKiroSteering = kiroSteeringFiles (evalDevenv nativeConfig);
        hmKiroInstruction = (hmKiroSteering."semble.md" or {}).text or "";
        hmClaudeRule = (hm.home.file.".claude/rules/semble.md" or {}).text or "";
      in
        lib.hasInfix "Use `semble search`" hmClaudeRule
        && lib.hasInfix "Use `semble search`" (hm.home.file.".codex/AGENTS.md".text or "")
        && hmKiroSteering ? "semble.md"
        && !(hmKiroSteering ? "instructions.md")
        && lib.hasInfix "name: semble" hmKiroInstruction
        && lib.hasInfix "inclusion: always" hmKiroInstruction
        && !(devenvKiroSteering ? "semble.md")
        && lib.hasInfix "Use `semble search`" devenv.files."AGENTS.md".text
    );

    module-semble-hm-devenv-option-parity = mkTest "semble-hm-devenv-option-parity" (
      let
        optionShape = options:
          lib.mapAttrs (_: option:
            if lib.isOption option
            then option.type.description
            else optionShape option)
          (lib.filterAttrs (name: _: name != "_module") options);
        programShape = evaluated: path:
          optionShape ((lib.getAttrFromPath path evaluated.options).type.getSubOptions []);
        hm = evalHm {};
        devenv = evalDevenv {};
      in
        programShape hm ["ai" "programs" "semble"]
        == programShape devenv ["ai" "programs" "semble"]
        && programShape hm ["ai" "codex" "programs" "semble"]
        == programShape devenv ["ai" "codex" "programs" "semble"]
        && builtins.attrNames (programShape hm ["ai" "programs" "semble"])
        == ["enable" "grammars" "instructions" "mcp" "package" "subagent"]
        && builtins.attrNames (programShape hm ["ai" "programs" "semble"]).mcp
        == ["content" "enable" "pathMappings" "rootExposure"]
        && builtins.attrNames (programShape hm ["ai" "programs" "semble"]).instructions
        == ["cli"]
        && lib.all
        (runtime: lib.hasAttrByPath ["ai" runtime "programs" "semble"] hm.options)
        ["claude" "codex" "kiro"]
        && lib.all
        (runtime: !(lib.hasAttrByPath ["ai" runtime "programs" "semble"] hm.options))
        ["copilot" "kimchi"]
    );

    module-semble-direct-helpers = mkTest "semble-direct-helpers" (
      let
        mkSemble = import ../lib/mkSemble.nix;
        helperPkgs = pkgs // {ai = aiStubs;};
        code = mkSemble {
          lib = hmLib;
          pkgs = helperPkgs;
        } {};
        all = mkSemble {
          lib = hmLib;
          pkgs = helperPkgs;
        } {content = "all";};
        codeAndDocs = mkSemble {
          lib = hmLib;
          pkgs = helperPkgs;
        } {content = ["docs" "code"];};
        allMixed =
          builtins.tryEval
          (mkSemble {
            lib = hmLib;
            pkgs = helperPkgs;
          } {content = ["all" "code"];}).args;
        duplicate =
          builtins.tryEval
          (mkSemble {
            lib = hmLib;
            pkgs = helperPkgs;
          } {content = ["docs" "docs"];}).args;
        empty =
          builtins.tryEval
          (mkSemble {
            lib = hmLib;
            pkgs = helperPkgs;
          } {content = [];}).args;
        records = import ../lib/integrations.nix;
      in
        code.type
        == "stdio"
        && code.args == []
        && lib.hasSuffix "/bin/semble-mcp" code.command
        && all.args == ["--content" "all"]
        && codeAndDocs.args == ["--content" "code" "docs"]
        && !allMixed.success
        && !duplicate.success
        && !empty.success
        && records.rule.source == ../cli-instructions.md
        && records.semanticAgent.instructions == ../cli-instructions.md
        && records.semanticAgent.tools == ["Bash" "Read"]
        && records.mcp.semanticAgent.instructions == ../mcp-agent-instructions.md
        && records.mcp.semanticAgent.tools
        == ["mcp__semble__find_related" "mcp__semble__search"]
        # `kiroAgent` is a typed record, not pre-rendered JSON. It deliberately
        # carries NO `name`: the typed `ai.kiro.agents` option defaults that from
        # the attr key, which keeps the id and the filename a single source of
        # truth. `prompt` stays a path here and is readFile-coerced at emission.
        && records.kiroAgent.tools == ["shell" "read"]
        && !(records.kiroAgent ? name)
        && records.kiroAgent.prompt == ../cli-instructions.md
        && records.mcp.kiroAgent.prompt == ../mcp-agent-instructions.md
        && records.mcp.kiroAgent.tools == ["@semble"]
    );

    # Semble contributes package defaults to real nullable pool entries. Those
    # defaults must live at the entry boundary: per-leaf defaults make nullOr
    # attempt to merge the null and submodule branches before precedence can
    # choose, producing "defined both null and not null" instead of a tombstone.
    module-semble-generated-pool-entries-accept-null = mkTest "semble-generated-pool-entries-accept-null" (
      let
        config = {
          ai = {
            programs.semble.enable = true;
            claude = {
              enable = true;
              agents.semble-search = null;
              mcpServers.semble = null;
            };
            codex = {
              enable = true;
              agents.semble-search = null;
              mcpServers.semble = null;
            };
            kiro = {
              enable = true;
              mcpServers.semble = null;
            };
          };
        };
        suppressed = evaluated:
          evaluated.config.ai.claude.agents.semble-search
          == null
          && evaluated.config.ai.claude.mcpServers.semble == null
          && evaluated.config.ai.codex.agents.semble-search == null
          && evaluated.config.ai.codex.mcpServers.semble == null
          && evaluated.config.ai.kiro.mcpServers.semble == null;
      in
        suppressed (evalHm config) && suppressed (evalDevenv config)
    );
  };
}
