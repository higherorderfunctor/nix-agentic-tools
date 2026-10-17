{
  aiModule = {
    files = import ./files/default.nix;
    runtimeModule = import ./runtime.nix;
    services = import ./services.nix;
  };
}
