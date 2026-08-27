{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  nixConfig = {
    extra-substituters = [
      "https://devenv.cachix.org"
      "https://nix-agentic-tools.cachix.org"
    ];
    extra-trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-agentic-tools.cachix.org-1:0jFprh5fkDez9mk6prYisYxzalr0hn78kyywGPXvOn0="
    ];
  };

  inputs = {
    # devenv — NO follows. Uses upstream cache (devenv.cachix.org).
    devenv.url = "github:cachix/devenv";
    git-branchless = {
      url = "github:arxanas/git-branchless";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Prebuilt Go toolchains (go.dev manifests) as `pkgs.go-bin`. Applied
    # INSIDE a package's `ourPkgs`, the same way rust-overlay is, so the
    # toolchain still comes from this repo's pin and cache-hit parity
    # holds. Only reached when a package's declared go.mod floor outruns
    # `ourPkgs.go` — see `goToolchainForFloor` in overlays/lib.nix.
    go-overlay = {
      url = "github:purpleclay/go-overlay";
      inputs = {
        git-hooks.follows = "git-hooks";
        nixpkgs.follows = "nixpkgs";
      };
    };
    llm-agents.url = "github:numtide/llm-agents.nix";
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Dev tooling — not published in overlays/modules, only used by
    # this repo's devenv tasks and CI pipeline.
    nix-fast-build = {
      url = "github:Mic92/nix-fast-build";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-update = {
      url = "github:Mic92/nix-update";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Deliberately different nixpkgs pin used ONLY by the
    # `checks.cache-hit-parity` regression gate to simulate a
    # consumer whose own nixpkgs diverges from ours. NO follows —
    # the whole point is that this pin drifts from `nixpkgs`. If
    # every overlay package uses `ourPkgs = import inputs.nixpkgs
    # { ... }` for build inputs (not `final`/`prev`), the store
    # paths stay byte-identical across the two pins and cachix
    # hits work for consumers regardless of their own pin.
    nixpkgs-test.url = "github:NixOS/nixpkgs/nixos-25.05";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    serena = {
      url = "github:oraios/serena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # strictdoc — taken from UPSTREAM'S OWN FLAKE, not built here. Its
    # uv.lock is the single source of truth for every Python dependency, so
    # the reqif pin and the pygments relaxation this repo used to carry
    # against nixpkgs' recipe are gone with the first-party build.
    #
    # NO follows, deliberately: the flake is a uv2nix package set locked and
    # tested against upstream's own nixpkgs, and rewriting that pin would
    # fork the set this repo does not own. It also keeps the package's store
    # path independent of any consumer's nixpkgs, which is what
    # checks.cache-hit-parity asserts. Swept by the normal flake-input
    # update (config/generate-update-ninja.nix derives its targets from
    # flake.lock), claimed by `passthru.updateFlakeInput` in
    # overlays/dev-tools/strictdoc.nix.
    strictdoc.url = "github:strictdoc-project/strictdoc";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;
    # Shared shell-hardening settings (bashOptions / shoptHeader /
    # shellcheckFlags) — see config/shell-strict.nix.
    shellStrict = import ./config/shell-strict.nix;
    supportedSystems = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = lib.genAttrs supportedSystems;
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [self.overlays.default];
      };
    # Bind each overlay once so `overlays.<name>` and the
    # `overlays.default` composition share the same import.
    aiOverlay = import ./overlays {inherit inputs;};
    codingStandardsOverlay = import ./packages/coding-standards {};
    stackedWorkflowsOverlay = import ./packages/stacked-workflows/overlay.nix {};

    # Barrel walker — collects non-binary facets from packages/*/default.nix.
    packagesBarrel = import ./packages;

    collectFacet = attrPath:
      lib.pipe packagesBarrel [
        (lib.filterAttrs (_: p: lib.hasAttrByPath attrPath p))
        (lib.mapAttrsToList (_: p: lib.getAttrFromPath attrPath p))
      ];

    packageLibContributions = lib.foldl' lib.recursiveUpdate {} (
      lib.mapAttrsToList (_: p: p.lib or {}) packagesBarrel
    );

    updateRegistry =
      (lib.evalModules {
        modules = [
          ./lib/update.nix
          ./config/update-targets.nix
          ./overlays/mcp-servers/effect-mcp.update.nix
        ];
      })
      .config.update;
  in {
    overlays = {
      ai = aiOverlay;
      coding-standards = codingStandardsOverlay;
      default = lib.composeManyExtensions [
        aiOverlay
        codingStandardsOverlay
        stackedWorkflowsOverlay
      ];
      stacked-workflows = stackedWorkflowsOverlay;
    };

    # Merged update-target registry — the single source of truth for
    # per-package update config (config/update-matrix.nix was dissolved into
    # this). Explicit 3-module import list (the barrel walker is deferred Track
    # B): lib/update.nix declares the option, config/update-targets.nix carries
    # the non-effect-mcp rows, and the co-located effect-mcp.update.nix
    # contributes its row. Consumed by config/generate-update-ninja.nix
    # (the ninja DAG) and update-pkg.sh (via
    # `nix eval --raw .#updateTargets.<name>.file`), and asserted
    # byte-identical to resolve_overlay_file by checks.update-targets-parity.
    updateTargets = updateRegistry.targets;

    # Merged cache-hit-parity registry — the six hardcoded package lists in
    # checks/cache-hit-parity.nix were dissolved into this. lib/checks.nix
    # declares the option and config/cache-hit-parity-targets.nix carries the
    # rows; lib.evalModules merges them. Consumed by checks/cache-hit-parity.nix
    # via self.cacheHitParityTargets.
    cacheHitParityTargets =
      (lib.evalModules {
        modules = [
          ./lib/checks.nix
          ./config/cache-hit-parity-targets.nix
        ];
      })
      .config.checks.cacheHitParity;

    homeManagerModules.default = {
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ collectFacet ["modules" "homeManager"];
    };

    devenvModules.nix-agentic-tools = {
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ collectFacet ["modules" "devenv"];
    };

    lib = let
      fragments = import ./lib/fragments.nix {inherit lib;};
      devshellLib = import ./lib/devshell.nix {inherit lib;};
      mcpLib = import ./lib/mcp.nix {inherit lib;};
      aiBase = import ./lib/ai {inherit lib;};

      # Cross-package presets (compose fragments from multiple
      # packages). Individual packages expose their own presets in
      # passthru.presets; these combine across package boundaries.
      #
      # We invoke the overlay functions with a stub `final` that
      # provides only `lib` and a fake `runCommand`. The overlay's
      # `passthru.fragments` attrset doesn't depend on the
      # derivation itself, only on `final.lib` (for the fragments
      # library import), so this is enough to extract fragment data
      # without instantiating a real pkgs set.
      stubFinal = {
        inherit lib;
        runCommand = name: _: _: {
          inherit name;
          type = "derivation";
        };
      };
      codingStdFragments =
        (codingStandardsOverlay stubFinal {}).coding-standards.passthru.fragments;
      swsContentFragments =
        (stackedWorkflowsOverlay stubFinal {}).stacked-workflows-content.passthru.fragments;
      presets = {
        # Full dev environment — all coding standards + skill routing
        nix-agentic-tools-dev = fragments.compose {
          fragments =
            builtins.attrValues codingStdFragments
            ++ builtins.attrValues swsContentFragments;
          description = "Full nix-agentic-tools dev standards";
        };
      };
      # Every flake-level helper lives under `lib.ai.*`. There are no
      # top-level `lib.<helper>` exports — consumers access everything
      # via `inputs.nix-agentic-tools.lib.ai.<helper>`.
      baseLib = {
        ai =
          aiBase
          // {
            inherit fragments presets;
            inherit (devshellLib) mkAgenticShell;
            inherit (fragments) compose mkFragment mkFrontmatter render;
            inherit (mcpLib) loadServer mkPackageEntry mkStdioEntry mkHttpEntry mkStdioConfig renderServer;
            mkMcpConfig = entries: {mcpServers = entries;};
            mapTools = f: lib.concatLists (lib.mapAttrsToList (server: tools: map (tool: f server tool) tools));
            externalServers = {
              aws-mcp = {
                type = "http";
                url = "https://knowledge-mcp.global.api.aws";
              };
            };
            # `gitConfig` / `gitConfigFull` defer to Chunk 8 (depends on
            # packages/stacked-workflows/modules/homeManager/git-config*.nix).
          };
      };
    in
      lib.recursiveUpdate baseLib packageLibContributions;

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      bareCommandsCheck = {bare-commands = import ./checks/bare-commands.nix {inherit pkgs;};};
      beadsContractsCheck = {beads-contracts = import ./checks/beads-contracts.nix {inherit pkgs;};};
      beadsLifecycleCheck = {beads-lifecycle = import ./checks/beads-lifecycle.nix {inherit lib pkgs self;};};
      cacheHitParityCheck = import ./checks/cache-hit-parity.nix {inherit inputs lib pkgs self;};
      codexCoverageCheck = import ./checks/chatgpt-codex-coverage.nix {inherit lib pkgs;};
      codexExtractedCheck = import ./checks/chatgpt-codex-extracted.nix {inherit pkgs self;};
      copilotWrapperArgvCheck = {copilot-wrapper-argv = import ./checks/copilot-wrapper-argv.nix {inherit lib pkgs;};};
      claudeDelegationClampCheck = {claude-delegation-clamp = import ./checks/claude-delegation-clamp.nix {inherit pkgs;};};
      claudeDevenvHooksRealTypeCheck = import ./checks/claude-devenv-hooks-real-type.nix {inherit pkgs inputs;};
      claudeExtractedCheck = import ./checks/claude-code-extracted.nix {inherit pkgs self;};
      claudeHeronBrookCheck = import ./checks/claude-heron-brook.nix {inherit lib pkgs self;};
      claudeMemoryCollisionGuardCheck = {claude-memory-collision-guard = import ./checks/claude-memory-collision-guard.nix {inherit pkgs;};};
      doubledWordsCheck = {doubled-words = import ./checks/doubled-words.nix {inherit pkgs;};};
      doubledWordsFixturesCheck = {doubled-words-fixtures = import ./checks/doubled-words-fixtures.nix {inherit pkgs;};};
      # #1019 mock-pilot bootstrap: evaluate the prospective facet composer
      # here while live package, overlay, and module aggregation stays unchanged.
      facetMockChecks = import ./checks/facet-mock.nix {inherit lib pkgs self;};
      factoryChecks = import ./checks/factory-eval.nix {inherit lib pkgs;};
      formattingCheck = import ./checks/formatting.nix {inherit inputs pkgs self;};
      fragmentsChecks = import ./checks/fragments-eval.nix {inherit lib pkgs;};
      glabExtractedCheck = import ./checks/glab-extracted.nix {inherit pkgs self;};
      goFloorDriftChecks = import ./checks/go-floor-drift.nix {inherit lib pkgs self;};
      goToolchainFloorChecks = import ./checks/go-toolchain-floor.nix {inherit inputs lib pkgs;};
      instructionsDriftCheck = import ./checks/instructions-drift.nix {inherit pkgs self;};
      kiroExtractedCheck = import ./checks/kiro-cli-extracted.nix {inherit pkgs self;};
      kiroFhsContractCheck = {kiro-fhs-contract = import ./checks/kiro-fhs-contract.nix {inherit pkgs;};};
      kiroWrapperArgvCheck = {kiro-wrapper-argv = import ./checks/kiro-wrapper-argv.nix {inherit lib pkgs;};};
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs;};
      optionsDocsCheck = import ./checks/options-doc.nix {inherit lib pkgs self;};
      pnpmFetcherParityCheck = import ./checks/pnpm-fetcher-parity.nix {inherit lib pkgs self;};
      sembleTemplatesCheck = import ./checks/semble-templates.nix {inherit lib pkgs self;};
      splitCodeSpansCheck = {split-code-spans = import ./checks/split-code-spans.nix {inherit pkgs;};};
      strictdocCycleCheck = {strictdoc-cycle-check = import ./checks/strictdoc-cycle-check.nix {inherit pkgs self;};};
      strictdocFpCheck = {strictdoc-fp-check = import ./checks/strictdoc-fp-check.nix {inherit pkgs self;};};
      strictdocGrammarCorpusCheck = {strictdoc-grammar-corpus = import ./checks/strictdoc-grammar-corpus.nix {inherit lib pkgs self;};};
      strictdocGrammarForeignRoundtripCheck = {strictdoc-grammar-foreign-roundtrip = import ./checks/strictdoc-grammar-foreign-roundtrip.nix {inherit lib pkgs self;};};
      strictdocGrammarModelEqualCheck = {strictdoc-grammar-model-equal = import ./checks/strictdoc-grammar-model-equal.nix {inherit lib pkgs self;};};
      strictdocGrammarNegativeFixturesCheck = {strictdoc-grammar-negative-fixtures = import ./checks/strictdoc-grammar-negative-fixtures.nix {inherit lib pkgs self;};};
      strictdocGrammarSurfaceCurrentCheck = {strictdoc-grammar-surface-current = import ./checks/strictdoc-grammar-surface-current.nix {inherit pkgs self;};};
      strictdocGrammarSurfaceLiveCheck = {strictdoc-grammar-surface-live = import ./checks/strictdoc-grammar-surface-live.nix {inherit lib pkgs self;};};
      updateTargetsParityCheck = {update-targets-parity = import ./checks/update-targets-parity.nix {inherit inputs lib pkgs self updateRegistry;};};
      validateAtStopCheck = {validate-at-stop = import ./checks/validate-at-stop.nix {inherit pkgs;};};
    in
      bareCommandsCheck // beadsContractsCheck // beadsLifecycleCheck // cacheHitParityCheck // claudeDelegationClampCheck // claudeDevenvHooksRealTypeCheck // claudeExtractedCheck // claudeHeronBrookCheck // claudeMemoryCollisionGuardCheck // codexCoverageCheck // codexExtractedCheck // copilotWrapperArgvCheck // doubledWordsCheck // doubledWordsFixturesCheck // facetMockChecks // factoryChecks // formattingCheck // fragmentsChecks // glabExtractedCheck // goFloorDriftChecks // goToolchainFloorChecks // instructionsDriftCheck // kiroExtractedCheck // kiroFhsContractCheck // kiroWrapperArgvCheck // moduleChecks // optionsDocsCheck // pnpmFetcherParityCheck // sembleTemplatesCheck // splitCodeSpansCheck // strictdocCycleCheck // strictdocFpCheck // strictdocGrammarCorpusCheck // strictdocGrammarForeignRoundtripCheck // strictdocGrammarModelEqualCheck // strictdocGrammarNegativeFixturesCheck // strictdocGrammarSurfaceCurrentCheck // strictdocGrammarSurfaceLiveCheck // updateTargetsParityCheck // validateAtStopCheck);

    # devShells.default provided by devenv CLI (devenv shell / devenv test)
    # from devenv.nix; nothing in this flake constructs it.
    # devShells.ci is a lightweight shell for the CI update pipeline.

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
      # Bind the fragment-composition data ONCE for all four
      # instruction-* derivations below. import is memoized so
      # the file is read once, but a single explicit binding is
      # clearer and cheaper to extend when a 5th ecosystem lands.
      # Shared with devenv.nix — see dev/instructions.nix for why. The
      # working tree is materialized from these exact derivations on every
      # shell entry, so a second rendering here would flip-flop the tree.
      instr = import ./dev/instructions.nix {
        inherit lib pkgs;
        inherit (inputs) treefmt-nix;
      };
    in
      # Grouped namespaces under pkgs.ai are flattened here for CLI ergonomics so
      # `nix build .#context7-mcp` works without knowing the group.
      # Adding a new package to the overlay automatically adds it
      # here; no flake.nix edit needed for new binaries.
      #
      # Legacy notes preserved for history:
      # - pkgs.nix-mcp-servers namespace dissolved in Milestone 5
      # - pkgs.{agnix,git-*} flat entries moved to pkgs.ai.* in Milestone 6
      # - github-copilot-cli renamed to copilot-cli in Milestone 4
      # - pkgs.ai.* grouped into mcpServers/lspServers/gitTools (factory arch)
      # Flat AI CLIs (strip nested groups which aren't derivations)
      builtins.removeAttrs pkgs.ai ["devTools" "generic" "gitTools" "lspServers" "mcpServers"]
      // pkgs.ai.devTools
      // pkgs.ai.generic
      // pkgs.ai.gitTools
      // builtins.removeAttrs pkgs.ai.mcpServers ["modelContextProtocol"]
      // pkgs.ai.lspServers
      // {
        # mono-repo combined package (nix-update target)
        modelcontextprotocol-all-mcps = pkgs.ai.mcpServers.modelContextProtocol.all-mcps;
        modelcontextprotocol-filesystem-mcp = pkgs.ai.mcpServers.modelContextProtocol.filesystem-mcp;
        # Custom Semble grammars absent from nixpkgs (tree-sitter-strictdoc)
        # ride the ordinary `pkgs.ai.generic.*` flattening above, so the
        # authenticated package sweep publishes them to Cachix without a
        # special-cased line here. Do not expose nixpkgs grammars again; the
        # nixpkgs follow already supplies those store paths. Keep patched
        # Semble check-only.
        # Instruction file derivations (from dev/generate.nix).
        # Each ecosystem produces a content directory consumed by the
        # `generate:instructions:*` devenv tasks.
        instructions-agents = instr.agents;
        instructions-claude = instr.claude;
        instructions-copilot = instr.copilot;
        instructions-kiro = instr.kiro;
        # Repo-root documents, same pipeline. The `generate:repo:*` tasks
        # build these by name; without them the tasks fail with
        # "attribute missing" and both files fall back to hand-editing.
        repo-contributing = instr.repoContributing;
        repo-readme = instr.repoReadme;
      });

    # devShells.default provided by devenv CLI (devenv shell / devenv test)
    # See devenv.nix for shell configuration.
    # devShells.ci is a lightweight shell for the CI update pipeline.
    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      ci = pkgs.mkShell {
        name = "nix-agentic-tools-ci";
        packages = with pkgs; [
          devenv
          jq
          nodejs
          prefetch-npm-deps
        ];
      };
    });

    # ── Apps ──────────────────────────────────────────────────────────
    apps = forAllSystems (system: let
      pkgs = pkgsFor system;
      ninjaFile = pkgs.writeText "update.ninja" (import ./config/generate-update-ninja.nix {inherit (self) updateTargets;});
    in {
      generate-update-ninja = {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "generate-update-ninja";
          extraShellCheckFlags = shellStrict.shellcheckFlags;
          inherit (shellStrict) bashOptions;
          text = ''
            ${shellStrict.shoptHeader}
            ${pkgs.coreutils}/bin/cp "${ninjaFile}" .update.ninja
            echo "Generated .update.ninja"
          '';
        }}/bin/generate-update-ninja";
      };
    });

    formatter =
      forAllSystems (system:
        (inputs.treefmt-nix.lib.evalModule (pkgsFor system) (import ./treefmt.nix)).config.build.wrapper);
  };
}
