# Reject a grouped-family change that alters compatibility's v8 load or
# serialize shape: the Go fixtures compare both transformations with explicit
# grouped and legacy YAML.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks.cliproxyapi-grouped-family = (extractedLib {inherit pkgs;}).goTest {
    name = "cliproxyapi-grouped-family-roundtrip";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
    packagePath = "internal/config";
    postTest = ''echo "ok — compatibility grouped load/serialize shape preserved" >"$out"'';
    run = "TestV8GroupedFamily.*";
    sources = {};
  };
}
