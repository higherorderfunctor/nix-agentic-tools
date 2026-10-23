{pkgs, ...}: let
  inherit (pkgs) lib;
in
  (pkgs.writeScriptBin "codeql-query" ''
    #!${pkgs.python3}/bin/python3
    ${builtins.readFile ../../../../../src/query.py}
  '').overrideAttrs (_: {
    meta = {
      description = "Query CodeQL databases through a local daemon or the CLI";
      license = lib.licenses.mit;
      mainProgram = "codeql-query";
    };
  })
