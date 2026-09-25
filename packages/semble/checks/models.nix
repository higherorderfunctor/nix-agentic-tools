# Content-routed embedding models: option shape, validation and warnings,
# routing text, the vanilla guarantee, and a network-free run of the patched
# CLI and MCP server against generated model2vec fixtures.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  customization = import ../lib/customization.nix {inherit lib;};
  customizePackage = import ../lib/customizePackage.nix {inherit lib pkgs;};
  records = import ../lib/integrations.nix;
  cliInstructions = ../cli-instructions.md;

  sembleScript = import ./semble-script.nix pkgs;

  # A tiny model2vec model, built offline from Semble's own closure.
  fixtureModel = seed:
    pkgs.runCommand "semble-fixture-model-${toString seed}" {} ''
      ${sembleScript "fixture-model" pkgs.ai.semble ./fixture-model.py} "$out" ${toString seed}
    '';
  docsModel = fixtureModel 1;
  codeConfigModel = fixtureModel 2;
  fallbackModel = fixtureModel 3;
  # Served from a seeded Hugging Face cache as Semble's built-in model.
  builtinModel = fixtureModel 4;
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
  # Like mkTest, but takes named conditions and names the ones that failed.
  expectAll = name: conditions: let
    failed = builtins.attrNames (lib.filterAttrs (_: passed: !passed) conditions);
  in
    mkTest name (failed == [] || throw "FAIL: ${name}: ${lib.concatStringsSep ", " failed}");

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
      }
      {
        argv = ["--content" "docs"];
        content = ["docs"];
      }
    ];
    defaultContent = ["code" "config"];
    preload = "${codeConfigModel}";
    calls = [
      {
        tool = "search";
        arguments.query = "alpha";
        model = "${codeConfigModel}";
      }
      {
        tool = "search";
        arguments = {
          query = "install guide";
          content = "docs";
        };
        model = "${docsModel}";
      }
      {
        tool = "find_related";
        arguments = {
          file_path = "README.md";
          line = 1;
          content = "docs";
        };
        model = "${docsModel}";
      }
      {
        tool = "search";
        arguments = {
          query = "alpha";
          content = "code";
        };
        model = "${fallbackModel}";
      }
    ];
    models = ["${codeConfigModel}" "${docsModel}" "${fallbackModel}"];
  });

  # The index directory suffix for a model other than Semble's own.
  hash = model: builtins.substring 0 16 (builtins.hashString "sha256" "${model}");
in {
  checks = {
    module-semble-models-option-shape = let
      hm = evalHm {};
      devenv = evalDevenv {};
      rootOptions = evaluated: evaluated.options.ai.programs.semble.type.getSubOptions [];
      runtimeOptions = hm.options.ai.kiro.programs.semble.type.getSubOptions [];
      entryOptions = evaluated: removeAttrs ((rootOptions evaluated).models.type.nestedTypes.elemType.getSubOptions []) ["_module"];
      options = entryOptions hm;
      root = rootOptions hm;
      mappingOptions = removeAttrs (root.pathMappings.type.nestedTypes.elemType.getSubOptions []) ["_module"];
      rejected = config: !(builtins.tryEval (builtins.deepSeq (evalHm config).config.ai.claude.mcpServers true)).success;
    in
      expectAll "semble-models-option-shape" {
        entryFields = builtins.attrNames options == ["content" "description" "enable" "model"];
        modelType = options.model.type.description == "package";
        modelRequired = !(options.model ? default);
        enableDefault = options.enable.default;
        descriptionOptional = options.description.default == null;
        modelsIsList = root.models.type.description == "list of (submodule)";
        modelsDefault = root.models.default == [];
        defaultContent = root.defaultContent.default == ["code"];
        defaultModel = root.defaultModel.default == null && root.defaultModel.type.description == "null or package";
        pathMappingsIsList = root.pathMappings.type.description == "list of (submodule)" && root.pathMappings.default == [];
        mappingFields = builtins.attrNames mappingOptions == ["content" "language" "patterns"];
        runtimeMappingsReplace = runtimeOptions.pathMappings.type.description == "null or (list of (submodule))";
        devenvParity = builtins.attrNames (entryOptions devenv) == builtins.attrNames options;
        # A runtime override replaces the whole list.
        runtimeListType = runtimeOptions.models.type.description == "null or (list of (submodule))";
        runtimeListDefault = runtimeOptions.models.default == null;
        finalPackageReadOnly = root.finalPackage.readOnly;
        # The old paths are gone, not aliased.
        cliModelsGone = rejected {ai.programs.semble.cli.models = [];};
        mcpContentGone = rejected {ai.programs.semble.mcp.content = "docs";};
        rootExposureGone = rejected {ai.programs.semble.mcp.rootExposure = false;};
        mcpPathMappingsGone = rejected {ai.programs.semble.mcp.pathMappings = [];};
      };

    # The program factory has no `pools` field (the keyed-models design needed
    # it; a list does not), and a runtime `models` list replaces the portable
    # one wholesale.
    module-semble-models-runtime-list = mkTest "semble-models-runtime-list" (
      let
        spec = {
          name = "fixture";
          supportedRuntimes = ["claude"];
          options.entries = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
          };
        };
        program = programFactory.mkProgram spec;
        evaluated = lib.evalModules {
          modules = [
            program.module
            {
              ai.programs.fixture.entries = ["root-a" "root-b"];
              ai.claude.programs.fixture.entries = ["runtime-a"];
            }
          ];
        };
        installed =
          builtins.head
          (evalHm {
            ai = {
              programs.semble = {
                enable = true;
                models = [docs];
                defaultContent = "docs";
              };
              kiro.programs.semble.models = [codeConfig];
              codex.programs.semble.models = [];
            };
          }).config.home.packages;
        tables = lib.mapAttrs (_: package: package.sembleModels.MODELS or null) installed.sembleRuntimePackages;
      in
        !(program ? pools)
        && !(program.spec ? pools)
        && (program.resolve evaluated.config "claude").entries == ["runtime-a"]
        && tables
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
        noDescription = withModels {models = [(removeAttrs docs ["description"])];};
      in
        failedWith "`models` entries 1, 2 all route content `docs`" duplicate
        && failedWith "`models` entries 1, 2 all route content `code config docs`" allCollision
        && allPass disabledTwin
        && failedWith "`models.1.content` must contain at least one category" emptyContent
        && failedWith "`models.1.model` does not hold a model2vec model" missingTokenizer
        && failedWith "Files given: config.json, model.safetensors, modules.json" missingTokenizer
        && allPass nestedLayout
        && failedWith "`defaultModel` does not hold a model2vec model" badDefaultModel
        && allPass noDescription
        # Direct callers get the same messages as a throw.
        && !(builtins.tryEval (customizePackage pkgs.ai.semble {models = [docs docs];}).drvPath).success
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

    module-semble-models-vanilla-identity = mkTest "semble-models-vanilla-identity" (
      let
        evaluated = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.instructions.enable = true;
            subagent.enable = true;
          };
        };
        finalPackage = evaluated.config.ai.programs.semble.finalPackage;
        rule = evaluated.config.ai.claude.rules.semble;
        disabledOnly = customizePackage pkgs.ai.semble {
          models = [(docs // {enable = false;})];
          defaultContent = "code";
        };
        grammarsOnly = customizePackage pkgs.ai.semble {grammars = [pkgs.tree-sitter-grammars.tree-sitter-awk];};
      in
        (customizePackage pkgs.ai.semble {}).drvPath
        == pkgs.ai.semble.drvPath
        && (customizePackage pkgs.ai.semble {
          models = [];
          defaultContent = ["code"];
          defaultModel = null;
          pathMappings = [];
          grammars = [];
        }).drvPath
        == pkgs.ai.semble.drvPath
        && disabledOnly.drvPath == pkgs.ai.semble.drvPath
        # The module installs upstream's derivation, only behind its launchers.
        && finalPackage.unwrapped.drvPath == pkgs.ai.semble.drvPath
        && finalPackage == builtins.head evaluated.config.home.packages
        # A grammar-only customization gets no models patch.
        && !(lib.elem ../patches/models.patch grammarsOnly.drvAttrs.patches)
        # A vanilla setup keeps the packaged rule and subagent byte for byte.
        && (records.forCli {}).rule == {source = cliInstructions;}
        && rule.source == cliInstructions
        && rule.text == builtins.readFile cliInstructions
        && evaluated.config.ai.claude.agents.semble-search.description == records.semanticAgent.description
    );

    module-semble-models-patch-selection = mkTest "semble-models-patch-selection" (
      let
        modelsOnly = customizePackage pkgs.ai.semble {models = [docs];};
        both = customizePackage pkgs.ai.semble {
          grammars = [pkgs.tree-sitter-grammars.tree-sitter-awk];
          models = [docs];
        };
        contentOnly = customizePackage pkgs.ai.semble {defaultContent = "docs";};
        defaultModelOnly = customizePackage pkgs.ai.semble {defaultModel = fallbackModel;};
        final = (evalHm {ai.programs.semble = routedSettings;}).config.ai.programs.semble.finalPackage;
        routedTable = (customizePackage pkgs.ai.semble routedSettings).passthru.sembleModels;
      in
        modelsOnly.drvAttrs.patches
        == [../patches/models.patch]
        && both.drvAttrs.patches == [../patches/extra-grammars.patch ../patches/models.patch]
        && contentOnly.drvAttrs.patches == [../patches/models.patch]
        && defaultModelOnly.drvAttrs.patches == [../patches/models.patch]
        && lib.hasInfix "semble_models.py" modelsOnly.drvAttrs.postPatch
        && !(lib.hasInfix "extra_grammars.py" modelsOnly.drvAttrs.postPatch)
        # The table drops disabled entries and expands and sorts content.
        && routedTable
        == {
          DEFAULT_CONTENT = ["code" "config"];
          DEFAULT_MODEL = "${fallbackModel}";
          MODELS = [
            {
              content = ["docs"];
              model = "${docsModel}";
            }
            {
              content = ["code" "config"];
              model = "${codeConfigModel}";
            }
          ];
        }
        && (customizePackage pkgs.ai.semble {defaultContent = "all";}).passthru.sembleModels.DEFAULT_CONTENT == ["code" "config" "docs"]
        # finalPackage wraps exactly the customized package.
        && final.unwrapped.drvPath == (customizePackage pkgs.ai.semble routedSettings).drvPath
    );

    # Mappings keep the consumer's list order, one entry per pattern: the
    # first match wins, and one language can map to several categories.
    module-semble-models-mapping-order = mkTest "semble-models-mapping-order" (
      customization.mappingList [
        {
          language = "json";
          content = "docs";
          patterns = ["docs/*.json"];
        }
        {
          language = "yaml";
          content = "config";
          patterns = ["special.lock"];
        }
        {
          language = "json";
          content = "config";
          patterns = ["*.json" "*.lock"];
        }
      ]
      == [
        {
          content = "docs";
          language = "json";
          pattern = "docs/*.json";
        }
        {
          content = "config";
          language = "yaml";
          pattern = "special.lock";
        }
        {
          content = "config";
          language = "json";
          pattern = "*.json";
        }
        {
          content = "config";
          language = "json";
          pattern = "*.lock";
        }
      ]
    );

    module-semble-models-routing-text = mkTest "semble-models-routing-text" (
      let
        evaluated = evalHm {
          ai = {
            programs.semble =
              routedSettings
              // {
                cli.instructions.enable = true;
                subagent.enable = true;
              };
            kiro.enable = true;
          };
        };
        rule = evaluated.config.ai.claude.rules.semble.text;
        agent = evaluated.config.ai.claude.agents.semble-search;
        kiroAgent = evaluated.config.ai.kiro.agents.semble-search;
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
        lib.all (text: count routingIntro text == 1 && count templateIntro text == 1 && !(lib.hasInfix "--model" text)) prompts
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
      export HOME="$TMPDIR/home"
      export HF_HOME="$TMPDIR/hf"
      export HF_HUB_OFFLINE=1
      snapshot="$HF_HOME/hub/models--minishlab--potion-code-16M-v2/snapshots/fixture"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME" "$snapshot" repo
      ${pkgs.coreutils}/bin/cp ${builtinModel}/* "$snapshot/"
      printf 'def alpha():\n    return beta\n' > repo/main.py
      printf '# Install guide\n\nalpha beta gamma\n' > repo/README.md
      printf '# Setup\n\ninstall guide beta\n' > repo/GUIDE.md
      printf '{"alpha": "config"}\n' > repo/settings.json

      jq=${pkgs.jq}/bin/jq
      warning="semble: no model is configured for content"
      indexes() {
        ${pkgs.findutils}/bin/find "$1" -mindepth 2 -maxdepth 2 -name 'index*' -type d -printf '%f\n' | ${pkgs.coreutils}/bin/sort | ${pkgs.coreutils}/bin/tr '\n' ' '
      }
      expect_indexes() {
        actual="$(indexes "$1")"
        if [ "$actual" != "$2" ]; then
          echo "FAIL: indexes after $3: got '$actual', expected '$2'" >&2
          exit 1
        fi
      }
      # expect_model CACHE INDEX-DIR MODEL
      expect_model() {
        actual="$($jq -r .model_path "$1"/*/"$2"/metadata.json)"
        if [ "$actual" != "$3" ]; then
          echo "FAIL: $2 was built with '$actual', expected '$3'" >&2
          exit 1
        fi
      }
      # run yes|no COMMAND...: whether the command must print the fallback
      # warning (exactly once) on stderr.
      run() {
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
      ${routed.config.home.activation.sembleCacheGuard.text}

      run no "$semble" search alpha repo
      expect_indexes "$cache" "index-code-config@${hash codeConfigModel} " "a plain search (defaultContent)"
      expect_model "$cache" "index-code-config@${hash codeConfigModel}" ${codeConfigModel}

      run no "$semble" search "install guide" repo --content docs
      run no "$semble" find-related README.md 1 repo --content docs
      expect_model "$cache" "index-docs@${hash docsModel}" ${docsModel}

      # --content replaces defaultContent wholesale: `code` alone has no entry.
      run yes "$semble" search alpha repo --content code
      ${pkgs.gnugrep}/bin/grep -Fx "$warning 'code'; using the default model" run.err
      expect_model "$cache" "index@${hash fallbackModel}" ${fallbackModel}

      # The disabled "all" entry routes nothing.
      run yes "$semble" search alpha repo --content all
      expect_indexes "$cache" "index-code-config-docs@${hash fallbackModel} index-code-config@${hash codeConfigModel} index-docs@${hash docsModel} index@${hash fallbackModel} " "every routed search"

      # The cache guard's `semble clear index` reaches every model's index.
      printf 'stale\n' > "$cache/.nix-package"
      ${routed.config.home.activation.sembleCacheGuard.text}
      expect_indexes "$cache" "" "the cache guard"

      # ── No models: a default model alone never warns ──
      run no ${silentPackage}/bin/semble search alpha repo
      expect_indexes ${silentCacheHome}/semble "index@${hash fallbackModel} " "a default model alone"

      # ── Vanilla: upstream's package and its built-in model ──
      run no ${vanillaPackage}/bin/semble search alpha repo
      expect_indexes ${vanillaCacheHome}/semble "index " "a vanilla search"
      expect_model ${vanillaCacheHome}/semble index minishlab/potion-code-16M-v2

      # ── MCP: per-call routing through the patched server ──
      export SEMBLE_CACHE_LOCATION="$TMPDIR/mcp-cache"
      ${sembleScript "mcp-routing" routedPackage ./mcp-routing.py} ${mcpExpectations} repo
      expect_indexes "$SEMBLE_CACHE_LOCATION" "index-code-config@${hash codeConfigModel} index-docs@${hash docsModel} index@${hash fallbackModel} " "MCP calls"
      ${pkgs.coreutils}/bin/touch "$out"
    '';
  };
}
