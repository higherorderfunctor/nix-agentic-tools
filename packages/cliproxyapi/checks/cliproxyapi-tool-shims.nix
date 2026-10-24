# Exercise the carried tool shims against the same source used by the
# package and extractor, including upstream OAuth regressions in the executor.
{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
in {
  checks.cliproxyapi-tool-shims = pkgs.linkFarm "cliproxyapi-tool-shims" (map (packagePath: {
      name = baseNameOf packagePath;
      path = (extractedLib {inherit pkgs;}).goTest {
        name = "cliproxyapi-tool-shims-${baseNameOf packagePath}";
        inherit package packagePath;
        sources = {};
        run = ".*";
        postTest = ''echo "ok — ${packagePath}: tool shim regressions" >"$out"'';
      };
    }) [
      "internal/config"
      "internal/runtime/executor"
      "internal/translator/openai/openai/responses"
      "internal/watcher/synthesizer"
    ]);
}
