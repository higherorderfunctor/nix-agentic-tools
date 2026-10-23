# The pack spec constructors, pure data over nixpkgs' lib, for a caller that
# holds this flake's `lib` but no package set with its overlay. They are the
# same functions as `pkgs.ai.devTools.codeql.mkQueryPack` and `mkModelPack`.
{lib, ...}: {
  ai.devTools.codeql = {
    inherit (import ./specs.nix {inherit lib;}) mkModelPack mkQueryPack;
    dumpEvalTables = import ./eval-tables.nix {inherit lib;};
  };
}
