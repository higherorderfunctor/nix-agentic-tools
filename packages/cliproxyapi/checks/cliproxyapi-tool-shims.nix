# Exercise the carried tool shims against the same source used by the
# package and extractor, including upstream OAuth regressions in the executor.
{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  shipped = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  # Upstream's payload tests fail past 20 ms of wall-clock time, which a busy CI
  # runner exceeds. Only this check's copy of the source raises those two limits
  # to 200 ms; the allocation and count assertions beside them stay as written.
  package =
    shipped
    // {
      src = pkgs.applyPatches {
        name = "cliproxyapi-tool-shims-source";
        inherit (shipped) src;
        patchFlags = ["-p1" "--fuzz=0"];
        patches = [./ci-timing.patch];
      };
    };
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
