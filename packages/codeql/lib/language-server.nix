# LSP accepts search-path, but not customizePackage's additional-packs.
{
  pkgs,
  searchPath,
}: let
  inherit (pkgs) lib;
  nixCodeql = pkgs.ai.devTools.codeql.codeql-extractor-nix.codeql;
  engine = nixCodeql.engine.customizePackage {
    searchPath = nixCodeql.warmEngine.packs.queries ++ searchPath;
  };
in
  (import ../../../lib/strict-shell-application.nix pkgs {
    name = "codeql-lsp";
    text = ''
      exec ${lib.getExe engine} execute language-server --check-errors=ON_CHANGE "$@"
    '';
  }).overrideAttrs (_: {
    meta = {
      description = "CodeQL language server with the Nix library and repository query pack";
      inherit (engine.meta) license platforms;
      mainProgram = "codeql-lsp";
    };
  })
