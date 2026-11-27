# Checks for packageLib.patchFlags (lib/packaging.nix): the flags' behavior on
# a fixture, and no backup or reject files in the real patched sources.
{
  packageLib,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs) lib;
in {
  checks = {
    # Build the exact updater used by preparation before accepting an input bump.
    nix-update-patch = self.ciNixUpdate.${pkgs.stdenv.hostPlatform.system};

    # Catch backup/reject leakage in actual patched source trees. These are the
    # recipes that expose their patched tree as a derivation; recipes that patch
    # inside their own build rely on patch-flags proving the shared list.
    patch-artifacts = let
      packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
      sources =
        map (name: packages.${name}.src) ["cliproxyapi" "cpa-manager-plus" "kimchi" "oxlint"]
        ++ map (name: packages.${name}.patchedSource) ["git-absorb" "git-branchless" "git-revise"]
        # CodeQL engines exist on x86_64-linux only, like the Kimchi CodeQL checks.
        ++ lib.optional (pkgs.stdenv.hostPlatform.system == "x86_64-linux") packages.kimchi.passthru.codeql.source;
    in
      pkgs.runCommand "patch-artifacts" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        bash ${./patch-artifacts.sh} ${lib.escapeShellArgs sources}
        touch "$out"
      '';
    # Offset success catches missing backup suppression; drift catches missing fuzz=0.
    patch-flags = let
      input = pkgs.writeTextDir "target" "offset\nheader\na\nold\nz\n";
      patchFile = pkgs.writeText "change.patch" ''
        --- a/target
        +++ b/target
        @@ -2,3 +2,3 @@
         a
        -old
        +new
         z
      '';
      patched = pkgs.applyPatches {
        src = input;
        patches = [patchFile];
        inherit (packageLib) patchFlags;
      };
    in
      pkgs.runCommand "patch-flags" {nativeBuildInputs = [pkgs.patch];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'offset\nheader\na\nnew\nz\n' > expected
        cmp expected ${patched}/target
        bash ${./patch-artifacts.sh} ${patched}
        cp ${input}/target target
        sed -i 's/^a$/changed/' target
        if patch ${lib.escapeShellArgs packageLib.patchFlags} < ${patchFile} > failure.log 2>&1; then
          echo 'changed context unexpectedly applied' >&2
          exit 1
        fi
        grep -Fx 'Hunk #1 FAILED at 2.' failure.log
        cp failure.log "$out"
      '';
  };
}
