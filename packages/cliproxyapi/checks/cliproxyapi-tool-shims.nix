# Exercise the carried tool shims against the same source used by the
# package and extractor, including upstream OAuth regressions in the executor.
{
  extractedLib,
  packageLib,
  pkgs,
  self,
  ...
}: let
  shipped = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  # Only this check's copy of the source carries these test-only patches.
  package =
    shipped
    // {
      src = pkgs.applyPatches {
        name = "cliproxyapi-tool-shims-source";
        inherit (shipped) src;
        inherit (packageLib) patchFlags;
        patches = [
          # Waits on the credits refresh state under the scoped key upstream
          # 16bf182f2088 adopted without updating the top-up recovery test.
          ./antigravity-credits-refresh-state-key.patch
          # Moves the Issue 6825 stream tests to the split tool-call arguments
          # upstream 4df055de9504 adopted without updating them.
          ./antigravity-tool-call-continuations.patch
          # Upstream's payload tests fail past 20 ms of wall-clock time, which a
          # busy CI runner exceeds. This raises those two limits to 200 ms; the
          # allocation and count assertions beside them stay as written.
          ./ci-timing.patch
        ];
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
