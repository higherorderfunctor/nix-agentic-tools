# Reject backups/rejects in the real source trees consumed by builds and checks.
{
  packageLib,
  pkgs,
  self,
  ...
}: {
  checks.patch-sources = let
    inherit (pkgs) lib;
    system = pkgs.stdenv.hostPlatform.system;
    packages = self.ciPackages.${system};
    sources = {
      cliproxyapi = packages.cliproxyapi.src;
      cliproxyapi-tool-shims = self.checks.${system}.cliproxyapi-tool-shims.patchedSource;
      cpa-manager-plus = packages.cpa-manager-plus.src;
      kimchi = packages.kimchi.patchedSource;
      oxlint = packages.oxlint.src;
    };
  in
    pkgs.runCommand "patch-sources" {
      passthru = {inherit sources;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir "$out"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: source: ''
          ln -s ${source} "$out/${name}"
          echo "patch-sources: ${name} (${source})"
          ${(packageLib.patching {inherit pkgs;}).validate ''"$out/${name}"''}
        '')
        sources)}
    '';
}
