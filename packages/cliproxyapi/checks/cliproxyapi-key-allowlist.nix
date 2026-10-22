# The Go tests patches/key-allowlist.patch carries, run against the patched
# source: the package build runs none (its subPackages is cmd/server alone).
# The auth package proves the predicate on every selection path; the access
# package proves query-parameter keys through the real middleware and that every
# config load refuses entries sharing a client key; the watcher package proves a
# hot reload that meets them keeps the running config. No check finds a
# candidate loop that skips the predicate, so a CPA bump needs review.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
  test = packagePath: sources:
    (extractedLib {inherit pkgs;}).goTest {
      name = "cliproxyapi-key-allowlist-${baseNameOf packagePath}";
      inherit package packagePath sources;
      postTest = ''echo "ok — ${packagePath}: access.key-allowlist tests" >"$out"'';
      run = "TestKeyAllowlist.*";
    };
in {
  checks.cliproxyapi-key-allowlist = pkgs.linkFarm "cliproxyapi-key-allowlist" (lib.mapAttrsToList (packagePath: sources: {
      name = baseNameOf packagePath;
      path = test packagePath sources;
    }) {
      "internal/access/config_access" = {};
      "internal/watcher" = {};
      "sdk/cliproxy/auth" = {};
    });
}
