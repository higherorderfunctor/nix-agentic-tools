# Checks for lib/packaging/patching.nix: helper behavior, real outputs, recipe bypasses.
{
  packageLib,
  pkgs,
  self,
  ...
}: {
  checks = {
    # Catch backup/reject leakage in actual helper-produced source trees.
    patch-artifacts = let
      packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
      sources =
        map (name: packages.${name}.src) ["cliproxyapi" "cpa-manager-plus" "kimchi" "oxlint"]
        ++ map (name: packages.${name}.patchedSource) ["git-absorb" "git-branchless" "git-revise"]
        # CodeQL engines exist on x86_64-linux only, like the Kimchi CodeQL checks.
        ++ pkgs.lib.optional (pkgs.stdenv.hostPlatform.system == "x86_64-linux") packages.kimchi.passthru.codeql.source;
    in
      pkgs.runCommand "patch-artifacts" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        bash ${./patch-artifacts.sh} ${pkgs.lib.escapeShellArgs sources}
        touch "$out"
      '';
    # Offset success catches missing backup suppression; drift catches missing fuzz=0.
    patch-helper = let
      patching = packageLib.patching {inherit pkgs;};
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
      patched = patching.source {
        src = input;
        patches = [patchFile];
      };
      apply = pkgs.writeShellScript "apply-fixture" (patching.command {patchFiles = [patchFile];});
    in
      pkgs.runCommand "patch-helper" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        printf 'offset\nheader\na\nnew\nz\n' > expected
        cmp expected ${patched}/target
        bash ${./patch-artifacts.sh} ${patched}
        cp ${input}/target target
        sed -i 's/^a$/changed/' target
        if ${apply} > failure.log 2>&1; then
          echo 'changed context unexpectedly applied' >&2
          exit 1
        fi
        grep 'FAILED' failure.log
        cp failure.log "$out"
      '';
    # Catch recipes bypassing the shared flags; local hooks use the same scanner.
    patch-policy = pkgs.runCommand "patch-policy" {nativeBuildInputs = [pkgs.ripgrep];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      bash ${./patch-policy.sh} ${../..}
      touch "$out"
    '';
  };
}
