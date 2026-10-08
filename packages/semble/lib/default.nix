{
  ai = {
    mcpServers.mkSemble = import ./mkSemble.nix;
    semble =
      import ./integrations.nix
      // {
        customizePackage = {
          lib,
          pkgs,
        }: package: spec: import ./launcher.nix {inherit lib pkgs;} {inherit package spec;};
      };
  };
}
