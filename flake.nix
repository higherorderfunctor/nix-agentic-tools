{
  description = "Agentic tools — skills, MCP servers, and home-manager modules for AI coding CLIs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    lib = nixpkgs.lib;
    supportedSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];
    forAllSystems = lib.genAttrs supportedSystems;
    pkgsFor = system: import nixpkgs {inherit system;};
    fragments = import ./lib/fragments.nix {inherit lib;};
  in {
    lib = {
      inherit fragments;
    };

    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.mkShell {
        name = "agentic-tools";
        packages = with pkgs; [
          alejandra
          dprint
        ];
      };
    });

    formatter = forAllSystems (system: (pkgsFor system).dprint);
  };
}
