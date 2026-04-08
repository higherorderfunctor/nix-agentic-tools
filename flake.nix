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
    lib = {};

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
