{
  inputs,
  pkgs,
}: let
  products = import ../../../../lib/packaging.nix {
    inherit (pkgs) lib;
    inherit inputs pkgs;
  };
in
  pkgs.ai.devTools.codeql.codeql-bare.customizePackage {
    extractors = [
      {
        language = "nix";
        schema = "nix.dbscheme";
        src = products.extractor;
      }
    ];
    libraries = [
      {
        language = "nix";
        name = "nix-agentic-tools/nix-all";
        schema = "nix.dbscheme";
        src = products.library;
      }
    ];
    queries = [products.queries];
  }
