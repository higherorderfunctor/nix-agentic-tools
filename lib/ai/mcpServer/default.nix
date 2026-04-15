{lib}: {
  commonSchema = import ./commonSchema.nix;
  mkMcpServer = import ./mkMcpServer.nix {inherit lib;};
  mkServiceModule = import ./mkServiceModule.nix {inherit lib;};
  serviceSchema = import ./serviceSchema.nix {inherit lib;};
}
