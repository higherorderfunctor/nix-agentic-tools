# Content-routed embedding models: option shape, validation and warnings,
# routing text, and a network-free run of the patched CLI and MCP server
# against generated model2vec fixtures.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows evalDevenv evalHm mkTest rejectsChange;
  inherit (import ../../../lib/packaging.nix) huggingFaceModelCacheDirName;
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  customizePackage = (import ../lib/default.nix).ai.semble.customizePackage {inherit lib pkgs;};

  runtimeConfig = package: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile package.passthru.sembleConfig));
  sembleScript = import ./semble-script.nix pkgs;

  fixtureModel = import ./fixture-model.nix pkgs;
  docsModel = fixtureModel 1;
  codeConfigModel = fixtureModel 2;
  fallbackModel = fixtureModel 3;
  # Served from a seeded Hugging Face cache as Semble's built-in model.
  builtinModel = fixtureModel 4;
  expectedBuiltinDefaultModelId = import ./expected-builtin-default-model-id.nix;
  builtinModelCacheDir = huggingFaceModelCacheDirName expectedBuiltinDefaultModelId;
  # A model package that lists its files, minus a real download.
  withFiles = files: model: model // {passthru = (model.passthru or {}) // {inherit files;};};

  docs = {
    model = docsModel;
    content = "docs";
    description = "Prose: READMEs and guides.";
  };
  codeConfig = {
    model = codeConfigModel;
    content = ["config" "code"];
  };

  failedWith = needle: evaluated:
    builtins.any
    (assertion: !assertion.assertion && lib.hasInfix needle assertion.message)
    evaluated.config.assertions;
  allPass = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
  count = needle: text: builtins.length (lib.splitString needle text) - 1;
  routingIntro = "Plain `semble search` in this setup searches";
  templateIntro = "Use `semble search` to discover code by behavior or meaning.";

  # ── Runtime fixtures ───────────────────────────────────────────
  routedSettings = {
    enable = true;
    models = [
      docs
      codeConfig
      {
        enable = false;
        model = fallbackModel;
        content = "all";
      }
    ];
    defaultContent = ["code" "config"];
    defaultModel = fallbackModel;
  };
  routedCacheHome = "/build/semble-models-routed";
  routed = evalHm {
    ai.programs.semble = routedSettings;
    xdg.cacheHome = routedCacheHome;
  };
  routedPackage = routed.config.ai.programs.semble.finalPackage;

  # No models, only a default model: customized, but never warns.
  silentCacheHome = "/build/semble-models-silent";
  silentPackage =
    (evalHm {
      ai.programs.semble = {
        enable = true;
        defaultModel = fallbackModel;
      };
      xdg.cacheHome = silentCacheHome;
    }).config.ai.programs.semble.finalPackage;

  vanillaCacheHome = "/build/semble-models-vanilla";
  vanillaPackage =
    (evalHm {
      ai.programs.semble.enable = true;
      xdg.cacheHome = vanillaCacheHome;
    }).config.ai.programs.semble.finalPackage;

  mcpExpectations = pkgs.writeText "semble-mcp-routing.json" (builtins.toJSON {
    argv = [
      {
        argv = [];
        content = ["code" "config"];
        name = "omitted CLI content uses the configured default";
        port = null;
      }
      {
        argv = ["--content" "docs"];
        content = ["docs"];
        name = "explicit CLI content replaces the configured default";
        port = null;
      }
      {
        argv = ["--http" "--port" "9001"];
        content = ["code" "config"];
        name = "HTTP mode forwards the requested port";
        port = 9001;
      }
    ];
    defaultContent = ["code" "config"];
    preload = "${codeConfigModel}";
    calls = [
      {
        tool = "search";
        arguments.query = "alpha";
        content = ["code" "config"];
        model = "${codeConfigModel}";
        name = "search without content uses the configured model and scope";
      }
      {
        tool = "search";
        arguments = {
          query = "install guide";
          content = "docs";
        };
        content = ["docs"];
        model = "${docsModel}";
        name = "explicit search content replaces the combined default";
      }
      {
        tool = "find_related";
        arguments = {
          file_path = "README.md";
          line = 1;
          content = "docs";
        };
        content = ["docs"];
        model = "${docsModel}";
        name = "find_related selects the docs index instead of the default";
      }
      {
        tool = "search";
        arguments = {
          query = "alpha";
          content = "code";
        };
        content = ["code"];
        model = "${fallbackModel}";
        name = "an unmatched set uses the fallback model, not a superset match";
      }
      {
        arguments = {
          content = "all";
          query = "alpha";
        };
        content = ["code" "config" "docs"];
        model = "${fallbackModel}";
        name = "a second fallback scope reuses the model but not the code index";
        tool = "search";
      }
    ];
    models = ["${codeConfigModel}" "${docsModel}" "${fallbackModel}"];
  });
in {
  checks = {
    module-semble-models-option-shape = let
      hm = evalHm {};
      devenv = evalDevenv {};
      rootOptions = evaluated: evaluated.options.ai.programs.semble;
      runtimeOptions = (rootOptions hm).runtimes.kiro;
      entryOptions = evaluated: removeAttrs ((rootOptions evaluated).models.type.nestedTypes.elemType.getSubOptions []) ["_module"];
      options = entryOptions hm;
      root = rootOptions hm;
      mappingOptions = removeAttrs (root.pathMappings.type.nestedTypes.elemType.getSubOptions []) ["_module"];
    in
      mkTest "semble-models-option-shape" (checkRows "model option contract" {
        "default model remains optional and accepts only packages" = root.defaultModel.default == null && root.defaultModel.type.description == "null or package";
        "devenv exposes the same model entry fields" = builtins.attrNames (entryOptions devenv) == builtins.attrNames options;
        "entries accept only the declared model fields" = builtins.attrNames options == ["content" "description" "enable" "model"];
        "entries need a package, not an unpinned name or a default" = options.model.type.description == "package" && !(options.model ? default);
        "finalPackage cannot be supplied by the consumer" =
          rejectsChange
          (config: let
            package = (evalHm config).config.ai.programs.semble.finalPackage;
          in
            (package.unwrapped or package).drvPath) {
            valid = {};
            invalid.ai.programs.semble.finalPackage = lib.mkForce pkgs.hello;
            expected = pkgs.ai.semble.drvPath;
          };
        "mapping entries expose language, category and patterns" = builtins.attrNames mappingOptions == ["content" "language" "patterns"];
        "mappings are ordered and unset by default" = root.pathMappings.type.description == "list of (submodule)" && root.pathMappings.default == [];
        "model descriptions may be omitted" = options.description.default == null;
        "model entries use an empty list, not a keyed model table" = root.models.type.description == "list of (submodule)" && root.models.default == [];
        "runtime mappings can inherit or replace the ordered list" = runtimeOptions.pathMappings.type.description == "null or (list of (submodule))";
        "runtime models can inherit or replace the ordered list" = runtimeOptions.models.type.description == "null or (list of (submodule))";
      });

    module-program-option-names = let
      spec = {
        name = "fixture";
        supportedRuntimes = ["claude"];
      };
      setting = lib.mkOption {
        type = lib.types.str;
        default = "default";
      };
      readSetting = options: let
        program = programFactory.mkProgram (spec // {inherit options;});
        evaluated = lib.evalModules {
          modules = [program.module {ai.programs.fixture.settings = "portable";}];
        };
      in
        (program.resolve evaluated.config "claude").settings;
    in
      mkTest "program-option-names" (checkRows "program factory option names" {
        "runtimes is reserved for the factory, settings is not" = rejectsChange readSetting {
          valid.settings = setting;
          invalid = {
            runtimes = setting;
            settings = setting;
          };
          expected = "portable";
        };
      });

    # A runtime can inherit, explicitly clear, or replace the portable model
    # list. The real launchers' JSON distinguishes all three states.
    module-semble-models-runtime-list = mkTest "semble-models-runtime-list" (
      let
        installed =
          builtins.head
          (evalHm {
            ai = {
              programs.semble = {
                enable = true;
                models = [docs];
                defaultContent = "docs";
                runtimes = {
                  codex.models = [];
                  kiro.models = [codeConfig];
                };
              };
            };
          }).config.home.packages;
        tables = lib.mapAttrs (_: package: (runtimeConfig package).models) installed.sembleRuntimePackages;
      in
        tables
        == {
          claude = [
            {
              content = ["docs"];
              model = "${docsModel}";
            }
          ];
          codex = [];
          kiro = [
            {
              content = ["code" "config"];
              model = "${codeConfigModel}";
            }
          ];
        }
    );

    module-semble-models-validation = mkTest "semble-models-validation" (
      let
        withModels = settings:
          evalHm {
            ai.programs.semble = {enable = true;} // settings;
          };
        # Enabled entries need distinct content sets; "all" is code config docs.
        duplicate = withModels {models = [docs (docs // {description = "Other prose.";})];};
        allCollision = withModels {
          models = [
            (docs // {content = "all";})
            (codeConfig // {content = ["docs" "code" "config"];})
          ];
        };
        disabledTwin = withModels {models = [docs (docs // {enable = false;})];};
        emptyContent = withModels {models = [(docs // {content = [];})];};
        missingTokenizer = withModels {
          models = [(docs // {model = withFiles ["config.json" "model.safetensors" "modules.json"] docsModel;})];
        };
        nestedLayout = withModels {
          models = [(docs // {model = withFiles ["0_StaticEmbedding/model.safetensors" "0_StaticEmbedding/tokenizer.json" "config_sentence_transformers.json"] docsModel;})];
        };
        badDefaultModel = withModels {defaultModel = withFiles ["config.json"] fallbackModel;};
      in
        checkRows "model routing restrictions" {
          "a disabled twin does not reserve its scope" = allPass disabledTwin;
          "a model must name at least one category" = failedWith "`models.1.content` must contain at least one category" emptyContent;
          "all reserves the same scope as its explicit expansion" = failedWith "`models` entries 1, 2 all route content `code config docs`" allCollision;
          "an incomplete default model reports the defaultModel path" = failedWith "`defaultModel` does not hold a model2vec model" badDefaultModel;
          "direct callers cannot build an ambiguous routing table" =
            rejectsChange
            (models: (runtimeConfig (customizePackage pkgs.ai.semble {inherit models;})).models) {
              valid = [docs];
              invalid = [docs docs];
              expected = [
                {
                  content = ["docs"];
                  model = "${docsModel}";
                }
              ];
            };
          "enabled entries cannot reserve the same scope" = failedWith "`models` entries 1, 2 all route content `docs`" duplicate;
          "nested weights and tokenizer are a valid layout" = allPass nestedLayout;
          "partial entry layout identifies the entry and the given files" =
            failedWith "`models.1.model` does not hold a model2vec model" missingTokenizer
            && failedWith "Files given: config.json, model.safetensors, modules.json" missingTokenizer;
        }
    );

    # An MCP call's `content` is one category or "all"; omitting it searches
    # defaultContent. A model for any other set is unreachable over MCP, so
    # evaluation warns, and the MCP subagent's description leaves it out.
    module-semble-models-mcp-reachability = mkTest "semble-models-mcp-reachability" (
      let
        settings = {
          enable = true;
          models = [docs codeConfig];
          defaultContent = "docs";
        };
        warningsFor = extra: (evalHm {ai.programs.semble = settings // extra;}).config.warnings;
        unreachable = "ai.programs.semble (claude, codex, kiro): `models.2` (content config code) is unreachable through MCP: an MCP call's `content` is one category or \"all\", and this set is not `defaultContent` either. Only the CLI can select it.";
        mcpDescription =
          (evalHm {
            ai.programs.semble =
              settings
              // {
                models = [docs codeConfig (docs // {content = "all";})];
                subagent = {
                  enable = true;
                  interface = "mcp";
                };
              };
          }).config.ai.claude.agents.semble-search.description;
      in
        warningsFor {}
        == [unreachable]
        # CLI-only: every set is reachable through `--content`.
        && warningsFor {
          mcp.enable = false;
          cli.instructions.enable = true;
        }
        == []
        # The same set as defaultContent is reachable by omitting `content`.
        && warningsFor {defaultContent = ["code" "config"];} == []
        && lib.hasInfix "for a call without `content` (Prose: READMEs and guides); `content: \"all\"` (Prose: READMEs and guides)." mcpDescription
        && !(lib.hasInfix "--content" mcpDescription)
        && !(lib.hasInfix "code config" mcpDescription)
    );

    module-semble-models-default-content-warning = mkTest "semble-models-default-content-warning" (
      let
        warningsFor = settings:
          (evalHm {
            ai.programs.semble = {enable = true;} // settings;
          }).config.warnings;
        dormant =
          (evalHm {
            ai.programs.semble.models = [docs];
          }).config.warnings;
      in
        warningsFor {models = [docs];}
        == ["ai.programs.semble (claude, codex, kiro): Semble `models` has no entry for `defaultContent` (code), so a plain `semble search` uses `defaultModel` and warns on every call."]
        && warningsFor {
          models = [docs];
          defaultContent = "docs";
        }
        == []
        # "all" matches its expansion.
        && warningsFor {
          models = [(docs // {content = "all";})];
          defaultContent = ["docs" "config" "code"];
        }
        == []
        && warningsFor {defaultModel = fallbackModel;} == []
        && warningsFor {models = [(docs // {enable = false;})];} == []
        # Only active integrations warn.
        && dormant == []
    );

    # A module config change selects a different JSON and launcher while
    # retaining the single first-party Semble build on both backends.
    module-semble-runtime-config-package-sharing = mkTest "semble-runtime-config-package-sharing" (
      let
        settings = [
          {}
          {grammars = [pkgs.tree-sitter-grammars.tree-sitter-awk];}
          {
            pathMappings = [
              {
                content = "code";
                language = "bash";
                patterns = [".envrc"];
              }
            ];
          }
          routedSettings
        ];
        packagesFor = evaluate:
          map (settings:
            (evaluate {ai.programs.semble = {enable = true;} // settings;}).config.ai.programs.semble.finalPackage)
          settings;
        sharesPackage = packages:
          lib.all (package: package.unwrapped.drvPath == pkgs.ai.semble.drvPath) packages
          && builtins.length (lib.unique (map (package: toString package.passthru.sembleConfig) packages)) == builtins.length settings;
        config = runtimeConfig routedPackage;
      in
        lib.all (evaluate: sharesPackage (packagesFor evaluate)) [evalHm evalDevenv]
        && config.models
        == [
          {
            content = ["docs"];
            model = "${docsModel}";
          }
          {
            content = ["code" "config"];
            model = "${codeConfigModel}";
          }
        ]
    );

    module-semble-models-routing-text = mkTest "semble-models-routing-text" (
      let
        records = import ../lib/integrations.nix;
        cliInstructions = ../cli-instructions.md;
        vanilla = evalHm {
          ai.programs.semble = {
            cli.instructions.enable = true;
            subagent.enable = true;
          };
        };
        evaluated = evalHm {
          ai = {
            programs.semble =
              routedSettings
              // {
                cli.instructions.enable = true;
                subagent.enable = true;
              };
            kiro.cli.enable = true;
          };
        };
        rule = evaluated.config.ai.claude.rules.semble.text;
        agent = evaluated.config.ai.claude.agents.semble-search;
        kiroAgent = evaluated.config.ai.kiro.native.agents.semble-search;
        mcpAgent =
          (evalHm {
            ai.programs.semble = {
              enable = true;
              models = [docs];
              subagent = {
                enable = true;
                interface = "mcp";
              };
            };
          }).config.ai.claude.agents.semble-search;
        contentOnlyRule =
          (evalHm {
            ai.programs.semble = {
              enable = true;
              cli.instructions.enable = true;
              defaultContent = "docs";
            };
          }).config.ai.claude.rules.semble.text;
        prompts = [rule agent.instructions.text kiroAgent.prompt.text];
      in
        (records.forCli {}).rule
        == {source = cliInstructions;}
        && vanilla.config.ai.claude.rules.semble.text == builtins.readFile cliInstructions
        && vanilla.config.ai.claude.agents.semble-search.description == records.semanticAgent.description
        && lib.all (text: count routingIntro text == 1 && count templateIntro text == 1 && !(lib.hasInfix "--model" text)) prompts
        && lib.hasPrefix "${routingIntro} `code config`. `--content` replaces that set for one call." rule
        && lib.hasInfix "- `--content docs`: Prose: READMEs and guides." rule
        && lib.hasInfix "- `--content code config` (plain `semble search`)\n" rule
        # A disabled entry is not listed.
        && count "- `--content" rule == 2
        && lib.hasInfix "Any other set uses the default model, and the CLI prints a warning." rule
        && lib.hasInfix "This setup has dedicated embedding models for --content docs (Prose: READMEs and guides); --content code config." agent.description
        && agent.description == kiroAgent.description
        && lib.hasInfix "`content: \"docs\"` (Prose: READMEs and guides)" mcpAgent.description
        && mcpAgent.instructions.source == ../mcp-agent-instructions.md
        && lib.hasPrefix "${routingIntro} `docs`. `--content` replaces that set for one call.\n\nUse `semble search`" contentOnlyRule
        && !(lib.hasInfix "embedding model" contentOnlyRule)
    );

    # The patched CLI and MCP server, offline, against generated models.
    module-semble-models-runtime = pkgs.runCommand "module-test-semble-models-runtime" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR/home"
      export HF_HOME="$TMPDIR/hf"
      export HF_HUB_OFFLINE=1
      snapshot="$HF_HOME/hub/${builtinModelCacheDir}/snapshots/fixture"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME" "$snapshot" repo
      ${pkgs.coreutils}/bin/cp ${builtinModel}/* "$snapshot/"
      printf 'def alpha():\n    return beta\n' > repo/main.py
      printf '# Install guide\n\nalpha beta gamma\n' > repo/README.md
      printf '# Setup\n\ninstall guide beta\n' > repo/GUIDE.md
      printf '{"alpha": "config"}\n' > repo/settings.json

      ${harness.hmRunShim}
      jq=${pkgs.jq}/bin/jq
      warning="semble: no model is configured for content"
      indexes() {
        ${pkgs.findutils}/bin/find "$1" -mindepth 2 -maxdepth 2 -name 'index*' -type d -printf '%f\n' | ${pkgs.gnused}/bin/sed -E 's/@[0-9a-f]{16}$/@model/' | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/tr '\n' ' '
      }
      expect_indexes() {
        actual="$(indexes "$1")"
        if [ "$actual" != "$2" ]; then
          echo "FAIL: indexes after $3: got '$actual', expected '$2'" >&2
          exit 1
        fi
      }
      # expect_model CACHE INDEX-SCOPE MODEL [custom]
      # Scope and persisted model are independent of the concrete store-path hash.
      expect_model() {
        dirs=("$1"/*/"$2")
        if [ "''${4:-}" = custom ]; then
          dirs=("$1"/*/"$2"@????????????????)
        fi
        if [ "''${#dirs[@]}" -ne 1 ]; then
          echo "FAIL: expected one $2 directory in $1, got ''${dirs[*]}" >&2
          exit 1
        fi
        actual="$($jq -r .model_path "''${dirs[0]}/metadata.json")"
        if [ "$actual" != "$3" ]; then
          echo "FAIL: $2 was built with '$actual', expected '$3'" >&2
          exit 1
        fi
      }
      # check yes|no COMMAND...: whether the command must print the fallback
      # warning (exactly once) on stderr. Not named `run`: that is
      # home-manager's dry-run helper, which the cache guard entry calls.
      check() {
        expect_warning="$1"
        shift
        "$@" > run.out 2> run.err || { status=$?; cat run.err >&2; echo "FAIL: '$*' exited $status" >&2; exit 1; }
        warnings="$(${pkgs.gnugrep}/bin/grep -c "^$warning" run.err || :)"
        if [ "$expect_warning" = yes ] && [ "$warnings" -ne 1 ]; then
          cat run.err >&2
          echo "FAIL: '$*' printed $warnings fallback warnings, expected 1" >&2
          exit 1
        fi
        if [ "$expect_warning" = no ] && [ "$warnings" -ne 0 ]; then
          cat run.err >&2
          echo "FAIL: '$*' warned without falling back" >&2
          exit 1
        fi
      }

      # ── Routed: defaultContent code config, two models, a fallback ──
      semble=${routedPackage}/bin/semble
      cache=${routedCacheHome}/semble
      # Record the package so the later guard run sees a change.
      ${routed.config.home.activation.ai-semble-cache-guard.text}

      check no "$semble" search alpha repo
      expect_indexes "$cache" "index-code-config@model " "a plain search (defaultContent)"
      expect_model "$cache" index-code-config ${codeConfigModel} custom

      check no "$semble" search "install guide" repo --content docs
      expect_model "$cache" index-docs ${docsModel} custom
      # A cold related search must itself build the docs index with the docs model.
      ${pkgs.coreutils}/bin/rm -r "$cache"/*/index-docs@*
      check no "$semble" find-related README.md 1 repo --content docs
      expect_model "$cache" index-docs ${docsModel} custom

      # --content replaces defaultContent wholesale: `code` alone has no entry.
      check yes "$semble" search alpha repo --content code
      ${pkgs.gnugrep}/bin/grep -Fx "$warning 'code'; using the default model" run.err
      expect_model "$cache" index ${fallbackModel} custom

      # The disabled "all" entry routes nothing.
      check yes "$semble" search alpha repo --content all
      expect_model "$cache" index-code-config-docs ${fallbackModel} custom
      routed_indexes="index-code-config-docs@model index-code-config@model index-docs@model index@model "
      expect_indexes "$cache" "$routed_indexes" "every routed search"

      # The cache guard's `semble clear index` reaches every model's index,
      # and a home-manager dry run clears none of them.
      printf 'stale\n' > "$cache/.nix-package"
      (
      export DRY_RUN=1
      ${routed.config.home.activation.ai-semble-cache-guard.text}
      )
      expect_indexes "$cache" "$routed_indexes" "a dry-run cache guard"
      ${pkgs.gnugrep}/bin/grep -Fx stale "$cache/.nix-package"
      ${routed.config.home.activation.ai-semble-cache-guard.text}
      expect_indexes "$cache" "" "the cache guard"

      # ── No models: a default model alone never warns ──
      check no ${silentPackage}/bin/semble search alpha repo
      expect_indexes ${silentCacheHome}/semble "index@model " "a default model alone"
      expect_model ${silentCacheHome}/semble index ${fallbackModel} custom

      # ── Vanilla: upstream's package and its built-in model ──
      check no ${vanillaPackage}/bin/semble search alpha repo
      expect_indexes ${vanillaCacheHome}/semble "index " "a vanilla search"
      expect_model ${vanillaCacheHome}/semble index ${lib.escapeShellArg expectedBuiltinDefaultModelId}

      # ── MCP: per-call routing through the patched server ──
      export SEMBLE_CACHE_LOCATION="$TMPDIR/mcp-cache"
      ${sembleScript "mcp-routing" routedPackage ./mcp-routing.py} ${mcpExpectations} repo
      expect_indexes "$SEMBLE_CACHE_LOCATION" "$routed_indexes" "MCP calls"
      # All three models coexist in one server; persisting one must not use
      # another call's model from the process environment.
      expect_model "$SEMBLE_CACHE_LOCATION" index-code-config-docs ${fallbackModel} custom
      expect_model "$SEMBLE_CACHE_LOCATION" index-code-config ${codeConfigModel} custom
      expect_model "$SEMBLE_CACHE_LOCATION" index-docs ${docsModel} custom
      expect_model "$SEMBLE_CACHE_LOCATION" index ${fallbackModel} custom
      ${pkgs.coreutils}/bin/touch "$out"
    '';
  };
}
