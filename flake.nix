{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  nixConfig = {
    extra-substituters = [
      "https://nix-agentic-tools.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-agentic-tools.cachix.org-1:0jFprh5fkDez9mk6prYisYxzalr0hn78kyywGPXvOn0="
    ];
  };

  inputs = {
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
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
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;
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
    # nvfetcher sources exposed on `final.nv-sources` per the
    # `dev/fragments/nix-standards/nix-standards.md` rule that
    # overlays must access nvfetcher sources via
    # `final.nv-sources.<key>` instead of importing
    # `generated.nix` directly. Compiled overlays then read
    # their own entry by name and merge in `hashes.json`
    # sidecar values for cargoHash etc. that nvfetcher can't
    # produce itself.
    nvSourcesOverlay = final: _prev: {
      nv-sources = import ./.nvfetcher/generated.nix {
        inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
      };
    };
    # Bind each overlay once so `overlays.<name>` and the
    # `overlays.default` composition share the same import.
    agnixOverlay = import ./packages/agnix {inherit inputs;};
    aiOverlay = import ./overlays {inherit inputs;};
    codingStandardsOverlay = import ./packages/coding-standards {};
    fragmentsAiOverlay = import ./packages/fragments-ai {};
    fragmentsDocsOverlay = import ./packages/fragments-docs {};
    gitToolsOverlay = import ./packages/git-tools {inherit inputs;};
    stackedWorkflowsOverlay = import ./packages/stacked-workflows {};

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
      agnix = agnixOverlay;
      ai = aiOverlay;
      coding-standards = codingStandardsOverlay;
      default = lib.composeManyExtensions [
        nvSourcesOverlay
        aiOverlay
        agnixOverlay
        codingStandardsOverlay
        fragmentsAiOverlay
        fragmentsDocsOverlay
        gitToolsOverlay
        stackedWorkflowsOverlay
      ];
      fragments-ai = fragmentsAiOverlay;
      fragments-docs = fragmentsDocsOverlay;
      git-tools = gitToolsOverlay;
      stacked-workflows = stackedWorkflowsOverlay;
    };

    homeManagerModules.nix-agentic-tools = {
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
      ai = import ./lib/ai {inherit lib;};

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
      baseLib = {
        inherit ai fragments presets;
        inherit (devshellLib) mkAgenticShell;
        inherit (fragments) compose mkFragment mkFrontmatter render;
        inherit (mcpLib) loadServer mkPackageEntry mkStdioEntry mkHttpEntry mkStdioConfig;
        mkMcpConfig = entries: {mcpServers = entries;};
        mapTools = f: lib.concatLists (lib.mapAttrsToList (server: tools: map (tool: f server tool) tools));
        externalServers = {
          aws-mcp = {
            type = "http";
            url = "https://knowledge-mcp.global.api.aws";
          };
        };
        # `gitConfig` / `gitConfigFull` defer to Chunk 8 (depends on
        # modules/stacked-workflows/git-config*.nix).
      };
    in
      lib.recursiveUpdate baseLib packageLibContributions;

    checks = forAllSystems (system: let
      pkgs = pkgsFor system;
      factoryChecks = import ./checks/factory-eval.nix {inherit lib pkgs;};
      fragmentsChecks = import ./checks/fragments-eval.nix {inherit lib pkgs;};
      moduleChecks = import ./checks/module-eval.nix {inherit lib pkgs;};
    in
      fragmentsChecks // factoryChecks // moduleChecks);

    # devShell provided by devenv CLI (devenv shell / devenv test)
    # See devenv.nix for shell configuration.

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      # Git tool packages — exposed via the git-tools overlay so
      # `nix build .#<name>` works for CI and consumers building
      # directly. The overlay's `ourPkgs` cache-hit-parity pattern
      # ensures these store paths match what CI pushes to cachix
      # regardless of the consumer's nixpkgs pin (see
      # `dev/fragments/overlays/cache-hit-parity.md` once it lands).
      inherit (pkgs) agnix git-absorb git-branchless git-revise;

      # All AI packages — CLIs and MCP servers — now live under pkgs.ai
      # (unified overlay). The legacy pkgs.nix-mcp-servers namespace was
      # dissolved as part of Milestone 5.
      # Note: github-copilot-cli has been renamed copilot-cli (dropped
      # the "github-" prefix) as part of the Milestone 4 factory port.
      inherit
        (pkgs.ai)
        any-buddy
        claude-code
        context7-mcp
        copilot-cli
        effect-mcp
        fetch-mcp
        git-intel-mcp
        git-mcp
        github-mcp
        kagi-mcp
        kiro-cli
        kiro-gateway
        mcp-language-server
        mcp-proxy
        nixos-mcp
        openmemory-mcp
        sequential-thinking-mcp
        serena-mcp
        sympy-mcp
        ;

      # Instruction file derivations (from dev/generate.nix).
      # Each ecosystem produces a content directory consumed by the
      # `generate:instructions:*` devenv tasks.
      instructions-agents = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.writeText "AGENTS.md" gen.agentsMd;

      instructions-claude = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
        files =
          {"CLAUDE.md" = gen.claudeMd;}
          // lib.mapAttrs' (
            name: content: lib.nameValuePair "rules/${name}" content
          )
          gen.claudeFiles;
      in
        pkgs.runCommand "instructions-claude" {} (
          "mkdir -p $out/rules\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}"
            )
            files
          )
        );

      instructions-copilot = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
        files =
          lib.mapAttrs' (
            name: content:
              lib.nameValuePair (
                if name == "copilot-instructions.md"
                then name
                else "instructions/${name}"
              )
              content
          )
          gen.copilotFiles;
      in
        pkgs.runCommand "instructions-copilot" {} (
          "mkdir -p $out/instructions\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText (baseNameOf name) content} $out/${name}"
            )
            files
          )
        );

      instructions-kiro = let
        gen = import ./dev/generate.nix {inherit lib pkgs;};
      in
        pkgs.runCommand "instructions-kiro" {} (
          "mkdir -p $out\n"
          + lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              name: content: "cp ${pkgs.writeText name content} $out/${name}"
            )
            gen.kiroFiles
          )
        );
    });

    # Standard flake outputs for `nix develop` and `nix fmt`.
    # Primary dev workflow is `devenv shell` / `devenv test` via
    # devenv.nix; these outputs preserve flake UX for users who
    # prefer plain Nix CLI.
    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        name = "nix-agentic-tools";
        packages = with pkgs; [
          alejandra
          treefmt
        ];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);
  };
}
