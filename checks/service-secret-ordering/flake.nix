{
  description = "Dev-only VM test: ai.services start and restart order against real sops-nix";

  # Pins only the fixture's own sources. This repository is read through
  # flake-compat from ../.., so its inputs come from the root flake.lock and
  # are never copied into this lock.
  inputs = {
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      flake = false;
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      flake = false;
    };
  };

  outputs = {
    flake-compat,
    home-manager,
    sops-nix,
    ...
  }: let
    nix-agentic-tools = (import flake-compat {src = ../..;}).defaultNix;
  in {
    checks.x86_64-linux.service-secret-ordering = import ./test.nix {
      inherit home-manager nix-agentic-tools sops-nix;
      inherit (nix-agentic-tools.inputs) nixpkgs;
    };
  };
}
