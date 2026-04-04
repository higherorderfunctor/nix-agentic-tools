{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  inputs = {
    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nvfetcher = {
      url = "github:berberman/nvfetcher";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    supportedSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [self.overlays.default];
      };
  in {
    # --- Overlays ---

    overlays = {
      default = _final: _prev: {
        # Composed from packages/default.nix once content migrates
      };
    };

    # --- Home-manager modules ---

    homeManagerModules = {
      copilot-cli = ./modules/copilot-cli;
      default = ./modules;
      kiro-cli = ./modules/kiro-cli;
      mcp-servers = ./modules/mcp-servers;
      stacked-workflows = ./modules/stacked-workflows;
    };

    # --- Library ---

    lib = {
      # MCP lib (mkStdioEntry, etc.) — populated in Phase 3
      # Fragment lib — populated in Phase 0.3
      # DevShell lib (mkAgenticShell) — populated in Phase 2
    };

    # --- Per-system outputs ---

    apps = forAllSystems (_system: {
      # generate, update, check-drift, check-health — populated in Phase 4
    });

    checks = forAllSystems (_system: {
      # Unified check suite — populated in Phase 3.7
    });

    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        name = "agentic-tools";
        packages = with pkgs; [
          # Formatters
          alejandra
          dprint
          shfmt

          # Linters
          deadnix
          shellcheck
          shellharden
          statix

          # Spell check
          nodePackages.cspell

          # LSPs
          bash-language-server
          marksman
          nixd
          taplo

          # Version tracking
          nvfetcher
        ];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).alejandra);

    packages = forAllSystems (_system: {
      # Populated as content migrates in Phase 3
    });
  };
}
