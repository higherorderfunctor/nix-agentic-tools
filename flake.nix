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
    # `ourPkgs.go` — see `goToolchainForFloor` in lib/packaging.nix.
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
    # packages/strictdoc/packages/ai/devTools/strictdoc/package.nix.
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
    instructionsFor = system:
      import ./dev/instructions.nix {
        inherit lib;
        pkgs = pkgsFor system;
        inherit (inputs) treefmt-nix;
      };
    repository = import ./lib/facets/repository.nix {
      inherit inputs;
      root = ./.;
      systems = supportedSystems;
    };
    updateRegistry = repository.update;
  in {
    overlays.default = repository.overlay;

    # Declarative owner contributions and workspace policy share native options.
    updateTargets = updateRegistry.targets;
    cacheHitParityTargets = repository.cacheHitParity;

    homeManagerModules.default = {
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ repository.moduleImports "homeManager";
    };

    devenvModules.nix-agentic-tools = {
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ repository.moduleImports "devenv";
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
      fragmentArgs = {
        inherit lib;
        inherit (repository) repoPath;
        fragmentsLib = fragments;
      };
      codingStdFragments = import ./packages/coding-standards/lib/fragments.nix fragmentArgs;
      swsContentFragments = import ./packages/stacked-workflows/lib/fragments.nix fragmentArgs;
      presets = {
        # Full dev environment — all coding standards + skill routing
        nix-agentic-tools-dev = fragments.compose {
          fragments =
            builtins.attrValues codingStdFragments
            ++ builtins.attrValues swsContentFragments;
          description = "Full nix-agentic-tools dev standards";
        };
      };
      # Shared AI primitives compose with the namespaces exported by owners.
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
      repository.libraryFor baseLib;

    checks = forAllSystems (system:
      repository.checksFor {
        inherit self updateRegistry;
        instr = instructionsFor system;
        pkgs = pkgsFor system;
        rootModules = (import ./lib/testing/discover.nix {inherit lib;}) ./checks;
      });

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
      instr = instructionsFor system;
    in
      repository.packagesFor {
        inherit pkgs system;
        rootPackages = {
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
        };
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
