let
  customizePackage = import ./customizePackage.nix;
in {
  ai = {
    mcpServers.mkSemble = import ./mkSemble.nix;
    semble =
      import ./integrations.nix
      // {
        inherit customizePackage;
      };
  };
}
