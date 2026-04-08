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

    # devShell provided by devenv CLI (devenv shell / devenv test)
    # See devenv.nix for shell configuration.
  };
}
