{
  aiModule = {
    catalog = import ./catalog/resolve.nix;
    catalogTypes = import ./catalog/types.nix;
    files = import ./files/default.nix;
    runtimeModule = import ./runtime.nix;
    services = import ./services.nix;
  };
}
