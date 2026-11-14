# Check Kimchi's installed runtime after packing; package hooks check build trees.
{
  packageLib,
  pkgs,
  self,
  ...
}: {
  checks.patch-sources = let
    packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
  in
    pkgs.runCommand "patch-sources" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${(packageLib.patching {inherit pkgs;}).validateDependencies {
        directory = "${packages.kimchi-workflows.toolchain}/node_modules/.runtime";
        layout = "runtime";
        patchedDependencies = packages.kimchi.patchedDependencies;
      }}
      echo 'PASS: installed runtime patched dependencies contain no backups or rejects' > "$out"
    '';
}
