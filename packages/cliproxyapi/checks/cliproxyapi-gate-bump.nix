# CPA's gate source contracts, offline over the same patched source as the build.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  facts = (extractedLib {inherit pkgs;}).load {dir = ../extracted;};
  config = (extractedLib {inherit pkgs;}).get facts.aggregate "config";
  switches = (import ../lib/exact-models.nix {inherit lib;}).settings;
  leaves = prefix: value:
    if builtins.isAttrs value && value != {}
    then lib.concatLists (lib.mapAttrsToList (key: leaves (prefix ++ [key])) value)
    else [lib.concatStringsSep "." prefix];
  missing = lib.filter (path: !(config ? ${path})) (leaves [] switches);
in {
  checks.cliproxyapi-gate-bump = (extractedLib {inherit pkgs;}).goTest {
    inherit package;
    name = "cliproxyapi-gate-bump";
    packagePath = "internal/config";
    sources = {
      "nat_gate_bump_test.go" = ./gate_bump_test.go;
      "nat_gate_golden.json" = ./fixtures/gate-bump-golden.json;
    };
    postTest = ''
      ${lib.optionalString (missing != []) ''
        echo ${lib.escapeShellArg "CPA gate forced switches disappeared: ${builtins.toJSON missing}"} >&2
        exit 1
      ''}
      echo 'CPA gate source golden and negative controls passed' > "$out"
    '';
    run = "TestNatGateBump.*";
  };
}
