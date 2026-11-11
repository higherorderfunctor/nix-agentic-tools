# Refuse dropped group fields, stale reload attributes, shared-URL alias mixups,
# config credentials classified as OAuth, missing management indexes and grants
# to unlisted clients or file-backed fake API keys. Tests live in the carried patch.
{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  test = packagePath:
    (extractedLib {inherit pkgs;}).goTest {
      name = "cliproxyapi-passthrough-${baseNameOf packagePath}";
      inherit package packagePath;
      postTest = ''echo "ok — ${packagePath}: passthrough config/auth assertions" >"$out"'';
      run = "(TestPassthrough.*|TestV8GroupedFamily.*)";
      sources = {};
    };
in {
  checks.cliproxyapi-passthrough = pkgs.linkFarm "cliproxyapi-passthrough" (map (packagePath: {
      name = baseNameOf packagePath;
      path = test packagePath;
    }) [
      "internal/api/handlers/management"
      "internal/config"
      "internal/watcher/synthesizer"
    ]);
}
