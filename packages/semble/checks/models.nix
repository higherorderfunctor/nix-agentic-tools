# Per-key embedding models: option shape, routing text, per-runtime pools,
# the vanilla guarantee, and a network-free run of the patched CLI and MCP
# entry points against generated model2vec fixtures.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  customizePackage = import ../lib/customizePackage.nix {inherit lib pkgs;};
  records = import ../lib/integrations.nix;
  cliInstructions = ../cli-instructions.md;

  # Reuse a Semble entry point's interpreter and complete Python path, then
  # append a script. `package` is any Semble build (patched or upstream).
  sembleScript = name: package: script:
    pkgs.runCommand "semble-script-${name}" {} ''
      ${pkgs.coreutils}/bin/head -n 3 ${package}/bin/.semble-wrapped > "$out"
      ${pkgs.coreutils}/bin/cat ${script} >> "$out"
      ${pkgs.coreutils}/bin/chmod +x "$out"
    '';

  # A tiny model2vec model, built offline from Semble's own closure.
  fixtureModel = seed:
    pkgs.runCommand "semble-fixture-model-${toString seed}" {} ''
      ${sembleScript "fixture-model" pkgs.ai.semble ./fixture-model.py} "$out" ${toString seed}
    '';
  proseModel = fixtureModel 1;
  defaultModel = fixtureModel 2;
  # The shape fetchFromHuggingFace returns, minus a real download.
  withFiles = files: model: model // {passthru = (model.passthru or {}) // {inherit files;};};

  prose = {
    model = proseModel;
    content = "docs";
    description = "Prose: READMEs and guides.";
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

  routingIntro = "This setup has several Semble embedding models.";
  templateIntro = "Use `semble search` to discover code by behavior or meaning.";

  # ── Runtime fixtures ───────────────────────────────────────────
  routedCacheHome = "/build/semble-models-routed";
  routed = evalHm {
    ai.programs.semble = {
      enable = true;
      cli.models.prose = prose;
    };
    xdg.cacheHome = routedCacheHome;
  };
  routedPackage = routed.config.ai.programs.semble.finalPackage;

  defaultOffCacheHome = "/build/semble-models-default-off";
  defaultOff = evalHm {
    ai.programs.semble = {
      enable = true;
      cli.models = {
        default = {
          enable = false;
          model = defaultModel;
          content = "config";
          description = "Fixture default model.";
        };
        inherit prose;
      };
    };
    xdg.cacheHome = defaultOffCacheHome;
  };
  defaultOffPackage = defaultOff.config.ai.programs.semble.finalPackage;

  mcpCases = pkgs.writeText "semble-mcp-model-cases.json" (builtins.toJSON {
    routed = [
      {
        argv = [];
        content = ["code"];
        model = null;
      }
      {
        argv = ["--content" "docs"];
        content = ["docs"];
        model = null;
      }
      {
        argv = ["--model" "prose"];
        content = ["docs"];
        model = "${proseModel}";
      }
      {
        argv = ["--model=prose" "--content" "config"];
        content = ["config"];
        model = "${proseModel}";
      }
      {
        argv = ["--model" "nope"];
        exit = 2;
      }
    ];
    # MCP never reads default.enable, and without --model it keeps upstream's
    # content default instead of inheriting default.content.
    defaultOff = [
      {
        argv = [];
        content = ["code"];
        model = "${defaultModel}";
      }
      {
        argv = ["--model" "default"];
        content = ["config"];
        model = "${defaultModel}";
      }
      {
        argv = ["--model" "prose"];
        content = ["docs"];
        model = "${proseModel}";
      }
    ];
  });
  mcpCasesFor = name:
    pkgs.runCommand "semble-mcp-cases-${name}.json" {} ''
      ${pkgs.jq}/bin/jq '.${name}' ${mcpCases} > "$out"
    '';
in {
  checks = {
    module-semble-models-option-shape = let
      hm = evalHm {};
      devenv = evalDevenv {};
      cliOptions = evaluated: (evaluated.options.ai.programs.semble.type.getSubOptions []).cli;
      entryOptions = evaluated: (cliOptions evaluated).models.type.nestedTypes.elemType.getSubOptions [];
      runtimeModels = (hm.options.ai.kiro.programs.semble.type.getSubOptions []).cli.models;
      options = removeAttrs (entryOptions hm) ["_module"];
      renamed = builtins.tryEval (evalHm {ai.programs.semble.instructions.cli.enable = true;}).config.ai.claude.rules;
    in
      expectAll "semble-models-option-shape" {
        entryFields = builtins.attrNames options == ["content" "description" "enable" "model"];
        modelType = options.model.type.description == "null or package";
        modelDefault = options.model.default == null;
        enableDefault = options.enable.default;
        contentDefault = options.content.default == ["code"];
        devenvParity = builtins.attrNames (removeAttrs (entryOptions devenv) ["_module"]) == builtins.attrNames options;
        # A runtime override is a per-key pool of nullable entries.
        runtimePoolType = runtimeModels.type.description == "attribute set of (null or (submodule))";
        runtimePoolDefault = runtimeModels.default == {};
        finalPackageReadOnly = (hm.options.ai.programs.semble.type.getSubOptions []).finalPackage.readOnly;
        # The old path is gone, not aliased.
        oldPathGone = !((hm.options.ai.programs.semble.type.getSubOptions []) ? instructions);
        oldPathRejected = !renamed.success;
      };

    module-semble-models-default-entry = mkTest "semble-models-default-entry" (
      let
        vanilla = evalHm {};
        extended = evalHm {ai.programs.semble.cli.models.prose = prose;};
        # A lower-priority definition of the whole set, as a shared profile
        # would write it, keeps its keys.
        lowPriority = evalHm {ai.programs.semble.cli.models = lib.mkDefault {inherit prose;};};
        models = evaluated: evaluated.config.ai.programs.semble.cli.models;
      in
        builtins.attrNames (models vanilla)
        == ["default"]
        && (models vanilla).default.enable
        && (models vanilla).default.model == null
        && (models vanilla).default.content == ["code"]
        # Adding a key does not discard the module-defined default.
        && builtins.attrNames (models extended) == ["default" "prose"]
        && (models extended).prose.content == ["docs"]
        && builtins.attrNames (models lowPriority) == ["default" "prose"]
        && (models lowPriority).default.model == null
    );

    module-semble-models-validation = mkTest "semble-models-validation" (
      let
        modelOnly = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models.default.model = defaultModel;
          };
        };
        # The routing block lists the default only while another key is
        # enabled, so only then is its description read.
        modelRouted = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models = {
              default.model = defaultModel;
              inherit prose;
            };
          };
        };
        noneEnabled = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models.default.enable = false;
          };
        };
        described = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models.default = {
              model = defaultModel;
              description = "Fixture default model.";
            };
          };
        };
        badKey = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models."Prose Docs" = prose;
          };
        };
        missingTokenizer = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models.prose =
              prose
              // {
                model = withFiles ["config.json" "model.safetensors" "modules.json"] proseModel;
              };
          };
        };
        nestedLayout = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models.prose =
              prose
              // {
                model = withFiles ["0_StaticEmbedding/model.safetensors" "0_StaticEmbedding/tokenizer.json" "config_sentence_transformers.json"] proseModel;
              };
          };
        };
        emptyContent = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.models.prose = prose // {content = [];};
          };
        };
        # An enabled non-default entry needs a description (nixpkgs' own
        # "has no value defined" error); a disabled one is never read.
        withoutDescription = enable:
          builtins.tryEval (builtins.deepSeq
            (evalHm {
              ai.programs.semble = {
                enable = true;
                cli = {
                  instructions.enable = true;
                  models.prose = {
                    inherit enable;
                    model = proseModel;
                  };
                };
              };
            })
            .config
            .ai
            .claude
            .rules
            .semble
            .text
            true);
      in
        allPass modelOnly
        && failedWith "cli.models.default.description must be set" modelRouted
        && failedWith "cli.models` must keep at least one entry enabled" noneEnabled
        && allPass described
        && failedWith ''key "Prose Docs" must match'' badKey
        && failedWith "Files given: config.json, model.safetensors, modules.json" missingTokenizer
        && failedWith "config.json, model.safetensors, tokenizer.json" missingTokenizer
        && allPass nestedLayout
        && failedWith "cli.models.prose.content` must contain at least one category" emptyContent
        && !(withoutDescription true).success
        && (withoutDescription false).success
    );

    # A runtime override resolves `cli.models` per key: null drops one key,
    # an entry replaces only its key, and `default` survives both.
    module-semble-models-runtime-pool = mkTest "semble-models-runtime-pool" (
      let
        evaluated = evalHm {
          ai = {
            programs.semble = {
              enable = true;
              cli = {
                instructions.enable = true;
                models.prose = prose;
              };
            };
            codex.programs.semble.cli.models.prose =
              prose
              // {
                content = "config";
                description = "Codex prose.";
              };
            kiro.programs.semble.cli.models.prose = null;
          };
        };
        packages = (builtins.head evaluated.config.home.packages).sembleRuntimePackages;
        # A runtime entry for one key leaves the portable `default` alone.
        customDefault = evalHm {
          ai = {
            programs.semble = {
              enable = true;
              cli.models.default = {
                model = defaultModel;
                description = "Fixture default model.";
              };
            };
            codex.programs.semble.cli.models.prose = prose;
          };
        };
        customPackages = (builtins.head customDefault.config.home.packages).sembleRuntimePackages;
        tombstoneDefault = evalHm {
          ai = {
            programs.semble.enable = true;
            kiro.programs.semble.cli.models.default = null;
          };
        };
      in
        builtins.attrNames packages.claude.sembleModels
        == ["default" "prose"]
        && packages.claude.sembleModels.prose.content == ["docs"]
        && builtins.attrNames packages.codex.sembleModels == ["default" "prose"]
        && packages.codex.sembleModels.prose.content == ["config"]
        # Kiro is back to the built-in default, so its package is upstream's.
        && !(packages.kiro ? sembleModels)
        && lib.hasInfix "semble-claude --model prose search` (content: docs): Prose" evaluated.config.ai.claude.rules.semble.text
        && lib.hasInfix "semble-codex --model prose search` (content: config): Codex prose." evaluated.config.ai.codex.rules.semble.text
        # Kiro renders the packaged guidance for its own command, no routing.
        && lib.hasInfix "semble-kiro search" evaluated.config.ai.kiro.rules.semble.text
        && !(lib.hasInfix "--model" evaluated.config.ai.kiro.rules.semble.text)
        && failedWith "must keep its `default` entry; set" tombstoneDefault
        && allPass customDefault
        && builtins.attrNames customPackages.codex.sembleModels == ["default" "prose"]
        && customPackages.codex.sembleModels.default.model == "${defaultModel}"
        && customPackages.claude.sembleModels.default.model == "${defaultModel}"
    );

    # `pools` defaults to [], so a program without it keeps nullable scalar
    # overrides, and a pool changes only its own path.
    module-semble-models-pools-scope = mkTest "semble-models-pools-scope" (
      let
        spec = {
          name = "fixture";
          supportedRuntimes = ["claude"];
          options = {
            enable = lib.mkEnableOption "fixture";
            entries = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
            };
          };
        };
        evaluate = programSpec: config:
          lib.evalModules {
            modules = [
              (programFactory.mkProgram programSpec).module
              {inherit config;}
            ];
          };
        shape = evaluated:
          lib.mapAttrs (_: option: {
            inherit (option) default;
            type = option.type.description;
          }) (lib.filterAttrs (name: _: name != "_module") (evaluated.options.ai.claude.programs.fixture.type.getSubOptions []));
        config = {
          ai.programs.fixture.entries = {
            a = "root-a";
            b = "root-b";
          };
          ai.claude.programs.fixture.entries.a = "runtime-a";
        };
        plain = evaluate spec config;
        explicit = evaluate (spec // {pools = [];}) config;
        pooled = evaluate (spec // {pools = [["entries"]];}) (lib.recursiveUpdate config {ai.claude.programs.fixture.entries.b = null;});
        resolve = programSpec: evaluated: (programFactory.mkProgram programSpec).resolve evaluated.config "claude";
        # A pool path that names no option fails rather than falling back to a
        # wholesale override.
        unknownPool = path: !(builtins.tryEval (programFactory.mkProgram (spec // {pools = [path];})).module).success;
        delegateSizing = ((evalHm {}).options.ai.codex.programs.delegate-sizing.type.getSubOptions []).enable;
      in
        shape plain
        == shape explicit
        && shape plain
        == {
          enable = {
            default = null;
            type = "null or boolean";
          };
          entries = {
            default = null;
            type = "null or (attribute set of string)";
          };
        }
        # Without a pool the runtime set replaces the portable set wholesale.
        && (resolve spec plain).entries == {a = "runtime-a";}
        && (resolve (spec // {pools = [["entries"]];}) pooled).entries == {a = "runtime-a";}
        && (resolve (spec // {pools = [["entries"]];}) (evaluate (spec // {pools = [["entries"]];}) config)).entries
        == {
          a = "runtime-a";
          b = "root-b";
        }
        && (shape pooled).enable == (shape plain).enable
        && (shape pooled).entries.default == {}
        && unknownPool ["entires"]
        && unknownPool ["entries" "a"]
        && !(unknownPool ["entries"])
        && delegateSizing.type.description == "null or boolean"
        && delegateSizing.default == null
    );

    module-semble-models-vanilla-identity = mkTest "semble-models-vanilla-identity" (
      let
        builtinDefault = {
          default = {
            enable = true;
            model = null;
            content = ["code"];
            description = null;
          };
        };
        evaluated = evalHm {
          ai.programs.semble = {
            enable = true;
            cli.instructions.enable = true;
          };
        };
        finalPackage = evaluated.config.ai.programs.semble.finalPackage;
        rule = evaluated.config.ai.claude.rules.semble;
        grammarsOnly = customizePackage pkgs.ai.semble [pkgs.tree-sitter-grammars.tree-sitter-awk] [] builtinDefault;
      in
        (customizePackage pkgs.ai.semble [] [] {}).drvPath
        == pkgs.ai.semble.drvPath
        && (customizePackage pkgs.ai.semble [] [] builtinDefault).drvPath == pkgs.ai.semble.drvPath
        && (customizePackage pkgs.ai.semble [] [] (builtinDefault // {default = builtinDefault.default // {content = "code";};})).drvPath == pkgs.ai.semble.drvPath
        # The module installs upstream's derivation, only wrapped for its cache.
        && finalPackage.drvAttrs.paths == ["${pkgs.ai.semble}"]
        && finalPackage == builtins.head evaluated.config.home.packages
        # A grammar-only customization gets no models patch.
        && !(lib.elem ../patches/models.patch grammarsOnly.drvAttrs.patches)
        # A vanilla setup keeps the packaged rule byte for byte.
        && (records.forCli {models = evaluated.config.ai.programs.semble.cli.models;}).rule == {source = cliInstructions;}
        && rule.source == cliInstructions
        && rule.text == builtins.readFile cliInstructions
    );

    module-semble-models-patch-selection = mkTest "semble-models-patch-selection" (
      let
        models = {inherit prose;};
        modelsOnly = customizePackage pkgs.ai.semble [] [] models;
        both = customizePackage pkgs.ai.semble [pkgs.tree-sitter-grammars.tree-sitter-awk] [] models;
        final = (evalHm {ai.programs.semble.cli.models = models;}).config.ai.programs.semble.finalPackage;
      in
        modelsOnly.drvAttrs.patches
        == [../patches/models.patch]
        && both.drvAttrs.patches == [../patches/extra-grammars.patch ../patches/models.patch]
        && lib.hasInfix "semble_models.py" modelsOnly.drvAttrs.postPatch
        && !(lib.hasInfix "extra_grammars.py" modelsOnly.drvAttrs.postPatch)
        && modelsOnly.passthru.sembleModels.prose.model == "${proseModel}"
        && modelsOnly.passthru.sembleModels.default.model == null
        # finalPackage wraps exactly the customized package.
        && final.drvAttrs.paths == ["${modelsOnly}"]
    );

    module-semble-models-routing-text = mkTest "semble-models-routing-text" (
      let
        evaluated = evalHm {
          ai = {
            programs.semble = {
              enable = true;
              cli = {
                instructions.enable = true;
                models = {
                  inherit prose;
                  settings = {
                    model = proseModel;
                    content = ["config" "code"];
                    description = "Configuration files.";
                  };
                  disabled = {
                    enable = false;
                    model = proseModel;
                  };
                };
              };
              subagent.enable = true;
            };
            kiro.enable = true;
          };
        };
        rule = evaluated.config.ai.claude.rules.semble.text;
        agentPrompt = evaluated.config.ai.claude.agents.semble-search.instructions.text;
        kiroPrompt = evaluated.config.ai.kiro.agents.semble-search.prompt.text;
        defaultOffRule =
          (evalHm {
            ai.programs.semble = {
              enable = true;
              cli = {
                instructions.enable = true;
                models = {
                  default.enable = false;
                  inherit prose;
                };
              };
            };
          }).config.ai.claude.rules.semble.text;
      in
        lib.all (text: count routingIntro text == 1 && count templateIntro text == 1) [rule agentPrompt kiroPrompt]
        && lib.hasPrefix routingIntro rule
        && lib.hasInfix "- `semble search` (content: code): Semble's built-in code model." rule
        && lib.hasInfix "- `semble --model prose search` (content: docs): Prose: READMEs and guides." rule
        && lib.hasInfix "- `semble --model settings search` (content: config code): Configuration files." rule
        && !(lib.hasInfix "--model disabled" rule)
        && lib.hasInfix "- Prefer `--model prose` over `--content docs`." rule
        && lib.hasInfix "- Prefer `--model settings` over `--content config`." rule
        && lib.hasInfix "- Pass the same `--model` (and `--content`) to `semble find-related`" rule
        && lib.hasInfix "- Always pass `--model`: plain `semble search` has no default model here." defaultOffRule
        && !(lib.hasInfix "- `semble search` (content" defaultOffRule)
    );

    # The patched CLI and MCP entry points, offline. `default` has no model, so
    # it resolves Semble's built-in model name, served from a seeded Hugging
    # Face cache; `prose` points at a generated model in the store.
    module-semble-models-runtime = pkgs.runCommand "module-test-semble-models-runtime" {} ''
      export HOME="$TMPDIR/home"
      export HF_HOME="$TMPDIR/hf"
      export HF_HUB_OFFLINE=1
      snapshot="$HF_HOME/hub/models--minishlab--potion-code-16M-v2/snapshots/fixture"
      ${pkgs.coreutils}/bin/mkdir -p "$HOME" "$snapshot" repo
      ${pkgs.coreutils}/bin/cp ${defaultModel}/* "$snapshot/"
      printf 'def alpha():\n    return beta\n' > repo/main.py
      printf '# Install guide\n\nalpha beta gamma\n' > repo/README.md
      printf '{"alpha": "config"}\n' > repo/settings.json

      jq=${pkgs.jq}/bin/jq
      semble=${routedPackage}/bin/semble
      cache=${routedCacheHome}/semble
      prose_hash="$(printf '%s' ${proseModel} | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -c1-16)"
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
      # expect_metadata INDEX-DIR JQ-FILTER EXPECTED
      expect_metadata() {
        actual="$($jq -c "$2" ${routedCacheHome}/semble/*/"$1"/metadata.json)"
        if [ "$actual" != "$3" ]; then
          echo "FAIL: $1 metadata $2: got '$actual', expected '$3'" >&2
          exit 1
        fi
      }
      run() {
        "$@" > run.out 2>&1 || { status=$?; cat run.out >&2; echo "FAIL: '$*' exited $status" >&2; exit 1; }
      }
      expect_error() {
        status=0
        "$@" > /dev/null 2> error.txt || status=$?
        [ "$status" -eq 2 ] || { echo "FAIL: '$*' exited $status, expected 2" >&2; exit 1; }
      }

      # Record the package so the later guard run sees a change.
      ${routed.config.home.activation.sembleCacheGuard.text}

      run "$semble" search alpha repo
      expect_indexes "$cache" "index " "default search"
      expect_metadata index .model_path '"minishlab/potion-code-16M-v2"'
      expect_metadata index .content_type '["code"]'

      run "$semble" --model prose search alpha repo
      expect_indexes "$cache" "index index-docs@$prose_hash " "--model before the subcommand"
      expect_metadata "index-docs@$prose_hash" .model_path '"${proseModel}"'

      run "$semble" search alpha repo --model prose
      run "$semble" find-related README.md 1 repo --model prose
      expect_indexes "$cache" "index index-docs@$prose_hash " "--model after the positionals"

      run "$semble" --model=prose search alpha repo --content code docs
      expect_indexes "$cache" "index index-code-docs@$prose_hash index-docs@$prose_hash " "--content replacing the entry's content"
      expect_metadata "index-code-docs@$prose_hash" .content_type '["code","docs"]'

      run "$semble" search alpha repo --content docs
      expect_indexes "$cache" "index index-code-docs@$prose_hash index-docs index-docs@$prose_hash " "--content on the default model"
      expect_metadata index-docs .model_path '"minishlab/potion-code-16M-v2"'

      expect_error "$semble" --model nope search alpha repo
      ${pkgs.gnugrep}/bin/grep -F "invalid choice: 'nope' (choose from 'default', 'prose')" error.txt
      expect_error "$semble" search alpha repo --model nope
      expect_error ${routedPackage}/bin/semble-mcp --model nope
      ${pkgs.gnugrep}/bin/grep -F "invalid choice: 'nope'" error.txt

      # The cache guard's `semble clear index` reaches every model's index.
      printf 'stale\n' > "$cache/.nix-package"
      ${routed.config.home.activation.sembleCacheGuard.text}
      expect_indexes "$cache" "" "the cache guard"

      semble=${defaultOffPackage}/bin/semble
      cache=${defaultOffCacheHome}/semble
      expect_error "$semble" search alpha repo
      ${pkgs.gnugrep}/bin/grep -F "the default model is disabled; pass --model (choose from 'prose')" error.txt
      expect_error "$semble" --model default search alpha repo
      ${pkgs.gnugrep}/bin/grep -F "invalid choice: 'default' (choose from 'prose')" error.txt
      run "$semble" search alpha repo --model prose
      expect_indexes "$cache" "index-docs@$prose_hash " "a disabled default"
      run "$semble" clear index
      expect_indexes "$cache" "" "clear index"

      ${sembleScript "mcp-routed" routedPackage ./mcp-model-resolution.py} ${mcpCasesFor "routed"}
      ${sembleScript "mcp-default-off" defaultOffPackage ./mcp-model-resolution.py} ${mcpCasesFor "defaultOff"}
      ${pkgs.coreutils}/bin/touch "$out"
    '';
  };
}
