{lib}: {
  commonSchema = import ./commonSchema.nix;
  mkMcpServer = import ./mkMcpServer.nix {inherit lib;};
}
