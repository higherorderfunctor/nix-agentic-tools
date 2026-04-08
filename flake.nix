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
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
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
      };
  in {
    overlays = {
      default = _final: _prev: {};
    };

    # Scaffolding placeholders — subsequent PRs populate these.
    devenvModules = {};
    homeManagerModules = {};

    lib = let
      fragments = import ./lib/fragments.nix {inherit lib;};
      devshellLib = import ./lib/devshell.nix {inherit lib;};
      mcpLib = import ./lib/mcp.nix {inherit lib;};
    in {
      inherit fragments;
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
      # `presets` defers to Chunk 4 (depends on coding-standards +
      # stacked-workflows content packages).
      # `gitConfig` / `gitConfigFull` defer to Chunk 8 (depends on
      # modules/stacked-workflows/git-config*.nix).
    };

    checks = forAllSystems (_: {});
    packages = forAllSystems (_: {});

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
