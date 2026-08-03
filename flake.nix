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
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Dev tooling — not published in overlays/modules, only used by
    # this repo's devenv tasks and CI pipeline.
    llm-agents.url = "github:numtide/llm-agents.nix";
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
    # the 20 non-effect-mcp rows, and the co-located effect-mcp.update.nix
    # contributes the last one. Consumed by config/generate-update-ninja.nix
    # (the ninja DAG) and update-pkg.sh (via
    # `nix eval --raw .#updateTargets.<name>.file`), and asserted
    # byte-identical to resolve_overlay_file by checks.update-targets-parity.
    updateTargets =
      (lib.evalModules {
        modules = [
          ./lib/update.nix
          ./config/update-targets.nix
          ./overlays/mcp-servers/effect-mcp.update.nix
        ];
      })
      .config.update.targets;

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
      cacheHitParityCheck = import ./checks/cache-hit-parity.nix {inherit inputs lib pkgs self;};
      codexCoverageCheck = import ./checks/chatgpt-codex-coverage.nix {inherit lib pkgs;};
      codexExtractedCheck = import ./checks/chatgpt-codex-extracted.nix {inherit pkgs self;};
      claudeDelegationClampCheck = {claude-delegation-clamp = import ./checks/claude-delegation-clamp.nix {inherit pkgs;};};
      claudeDevenvHooksRealTypeCheck = import ./checks/claude-devenv-hooks-real-type.nix {inherit pkgs inputs;};
      claudeExtractedCheck = import ./checks/claude-code-extracted.nix {inherit pkgs self;};
      claudeHeronBrookCheck = import ./checks/claude-heron-brook.nix {inherit pkgs;};
      factoryChecks = import ./checks/factory-eval.nix {inherit lib pkgs;};
      formattingCheck = import ./checks/formatting.nix {inherit inputs pkgs self;};
      fragmentsChecks = import ./checks/fragments-eval.nix {inherit lib pkgs;};
      glabExtractedCheck = import ./checks/glab-extracted.nix {inherit pkgs self;};
      goToolchainFloorChecks = import ./checks/go-toolchain-floor.nix {inherit inputs lib pkgs;};
      instructionsDriftCheck = import ./checks/instructions-drift.nix {inherit pkgs self;};
      kiroExtractedCheck = import ./checks/kiro-cli-extracted.nix {inherit pkgs self;};
      kiroWrapperArgvCheck = {kiro-wrapper-argv = import ./checks/kiro-wrapper-argv.nix {inherit lib pkgs;};};
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs;};
      optionsDocsCheck = import ./checks/options-doc.nix {inherit lib pkgs self;};
      pnpmFetcherParityCheck = import ./checks/pnpm-fetcher-parity.nix {inherit lib pkgs self;};
      splitCodeSpansCheck = {split-code-spans = import ./checks/split-code-spans.nix {inherit pkgs;};};
      updateTargetsParityCheck = {update-targets-parity = import ./checks/update-targets-parity.nix {inherit lib pkgs self;};};
      validateAtStopCheck = {validate-at-stop = import ./checks/validate-at-stop.nix {inherit pkgs;};};
    in
      bareCommandsCheck // cacheHitParityCheck // claudeDelegationClampCheck // claudeDevenvHooksRealTypeCheck // claudeExtractedCheck // claudeHeronBrookCheck // codexCoverageCheck // codexExtractedCheck // factoryChecks // formattingCheck // fragmentsChecks // glabExtractedCheck // goToolchainFloorChecks // instructionsDriftCheck // kiroExtractedCheck // kiroWrapperArgvCheck // moduleChecks // optionsDocsCheck // pnpmFetcherParityCheck // splitCodeSpansCheck // updateTargetsParityCheck // validateAtStopCheck);

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
      # Grouped namespaces (pkgs.ai.mcpServers.*, pkgs.ai.lspServers.*,
      # pkgs.gitTools.*) are flattened here for CLI ergonomics so
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
      builtins.removeAttrs pkgs.ai ["mcpServers" "lspServers"]
      // builtins.removeAttrs pkgs.ai.mcpServers ["modelContextProtocol"]
      // pkgs.ai.lspServers
      // pkgs.devTools
      // pkgs.generic
      // pkgs.gitTools
      // {
        # mono-repo combined package (nix-update target)
        modelcontextprotocol-all-mcps = pkgs.ai.mcpServers.modelContextProtocol.all-mcps;
        modelcontextprotocol-filesystem-mcp = pkgs.ai.mcpServers.modelContextProtocol.filesystem-mcp;
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
