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
    # Locked binary toolchains are constructed over each recipe's package set
    # through the input libraries; nixpkgs' own Go and Rust are never selected.
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
    microvm = {
      url = "github:microvm-nix/microvm.nix";
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
    forAllSystems = lib.genAttrs repository.supportedSystems;
    # The internal unfree-enabled package set: checks, repo documents, the CI
    # shell, apps and the formatter. Bound once per system so they share one
    # nixpkgs evaluation.
    ciSet = forAllSystems (system:
      repository.natSetFor {
        inherit system;
        config.allowUnfree = true;
      });
    pkgsFor = system: ciSet.${system};
    repoDocsFor = system:
      import ./dev/repo-docs.nix {
        inherit lib;
        pkgs = pkgsFor system;
        inherit (inputs) treefmt-nix;
      };
    repository = import ./lib/facets/repository.nix {
      inherit inputs;
      root = ./.;
    };
    updateRegistry = repository.update;
  in {
    overlays.default = repository.overlay;

    # Declarative owner contributions and workspace policy share native options.
    updateTargets = updateRegistry.targets;

    homeManagerModules.default = {
      ai.internal.treefmtNix = inputs.treefmt-nix;
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ repository.moduleImports "homeManager";
    };

    treefmtModules.default = ./lib/treefmt-module.nix;

    devenvModules.nix-agentic-tools = {
      ai.internal.treefmtNix = inputs.treefmt-nix;
      imports =
        [./lib/ai/sharedOptions.nix]
        ++ repository.moduleImports "devenv";
    };

    lib = let
      fragments = import ./lib/fragments.nix {inherit lib;};
      mcpLib = import ./lib/mcp.nix {inherit lib;};
      aiBase = import ./lib/ai {inherit lib;};
      aiTypes = import ./lib/ai/types.nix {inherit lib;};

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
      delegateRoutingFragments = import ./packages/delegate-routing/lib/fragments.nix fragmentArgs;
      swsContentFragments = import ./packages/stacked-workflows/lib/fragments.nix fragmentArgs;
      presets = {
        # Full dev environment — all coding standards + skill routing
        nix-agentic-tools-dev = fragments.compose {
          fragments =
            builtins.attrValues codingStdFragments
            ++ builtins.attrValues delegateRoutingFragments
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
            types = aiTypes;
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
            # packages/stacked-workflows/lib/git-config*.nix).
          };
        # Consumer-facing packaging helpers. Only this one is public; the rest
        # of lib/packaging.nix is the repo's own update/build tooling. It takes
        # the caller's `pkgs` as an argument, so it builds on their nixpkgs.
        packaging = {inherit (import ./lib/packaging.nix) fetchHuggingFaceModel;};
      };
    in
      repository.libraryFor baseLib;

    checks = forAllSystems (system:
      repository.checksFor {
        inherit self updateRegistry;
        pkgs = pkgsFor system;
        rootModules = (import ./lib/testing/discover.nix {inherit lib;}) ./checks;
      });

    # devShells.default provided by devenv CLI (devenv shell / devenv test)
    # from devenv.nix; nothing in this flake constructs it.
    # devShells.ci is a lightweight shell for the CI update pipeline.

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
      repoDocs = repoDocsFor system;
    in
      repository.packagesFor {
        inherit pkgs;
        rootPackages = {
          # Repo-root documents from dev/generate.nix. The `generate:repo:*`
          # tasks build these by name; without them the tasks fail with
          # "attribute missing" and both files fall back to hand-editing.
          # The agent instruction files are not packages: `ai.*` writes them
          # (dev/ai.nix).
          repo-contributing = repoDocs.repoContributing;
          repo-readme = repoDocs.repoReadme;
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
