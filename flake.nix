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
    aiOverlay = import ./overlays {inherit inputs;};
    codingStandardsOverlay = import ./packages/coding-standards {};
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
      ai = aiOverlay;
      coding-standards = codingStandardsOverlay;
      default = lib.composeManyExtensions [
        nvSourcesOverlay
        aiOverlay
        codingStandardsOverlay
        stackedWorkflowsOverlay
      ];
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
      # Bind the fragment-composition data ONCE for all four
      # instruction-* derivations below. import is memoized so
      # the file is read once, but a single explicit binding is
      # clearer and cheaper to extend when a 5th ecosystem lands.
      gen = import ./dev/generate.nix {inherit lib pkgs;};
    in
      # All AI packages — CLIs, git tools, and MCP servers — live
      # under pkgs.ai (unified overlay) and are exposed flat at
      # packages.<system>.<name> for CLI ergonomics (`nix build .#<name>`).
      # Adding a new package to the overlay automatically adds it
      # here; no flake.nix edit needed for new binaries.
      #
      # Legacy notes preserved for history:
      # - pkgs.nix-mcp-servers namespace dissolved in Milestone 5
      # - pkgs.{agnix,git-*} flat entries moved to pkgs.ai.* in Milestone 6
      # - github-copilot-cli renamed to copilot-cli in Milestone 4
      pkgs.ai
      // {
        # Instruction file derivations (from dev/generate.nix).
        # Each ecosystem produces a content directory consumed by the
        # `generate:instructions:*` devenv tasks.
        instructions-agents = pkgs.writeText "AGENTS.md" gen.agentsMd;

        instructions-claude = let
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

        instructions-kiro = pkgs.runCommand "instructions-kiro" {} (
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
