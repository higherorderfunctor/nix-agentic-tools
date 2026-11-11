# Refuse config/auth regressions, HTTP bypasses of conductor selection, changed
# raw bytes, wrong client usage attribution, stale reloads and raw models leaked
# into chat routes or catalogs. Tests use local upstreams in the carried patch.
{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  test = packagePath:
    (extractedLib {inherit pkgs;}).goTest {
      name = "cliproxyapi-passthrough-${builtins.replaceStrings ["/"] ["-"] packagePath}";
      inherit package packagePath;
      postTest = ''echo "ok — ${packagePath}: passthrough config/auth/route assertions" >"$out"'';
      run = "(TestPassthrough.*|TestV8GroupedFamily.*)";
      sources = {};
    };
in {
  checks.cliproxyapi-passthrough = pkgs.linkFarm "cliproxyapi-passthrough" (map (packagePath: {
      name = builtins.replaceStrings ["/"] ["-"] packagePath;
      path = test packagePath;
    }) [
      "internal/api"
      "internal/api/handlers/management"
      "internal/config"
      "internal/registry"
      "internal/runtime/executor"
      "internal/watcher/synthesizer"
      "sdk/api/handlers/..."
      "sdk/cliproxy"
      "sdk/cliproxy/auth"
    ]);
}
