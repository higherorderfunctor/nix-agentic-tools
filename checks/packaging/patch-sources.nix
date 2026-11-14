# Reject backups/rejects in the real source trees consumed by builds and checks.
{
  inputs,
  packageLib,
  pkgs,
  self,
  ...
}: {
  checks.patch-sources = let
    inherit (pkgs) lib;
    system = pkgs.stdenv.hostPlatform.system;
    packages = self.ciPackages.${system};
    # Keep the actual unpack/patch phases, inputs and hooks. References to the
    # package output must stay its output, rather than the source-view output.
    # Discard only the string context so inspection does not build the binaries.
    sourceOnly = package:
      pkgs.srcOnly (package.overrideAttrs (old: {
        postPatch =
          lib.replaceStrings ["$out" "\${out}"]
          (lib.replicate 2 (builtins.unsafeDiscardStringContext package.outPath))
          (old.postPatch or "");
      }));
    sources =
      {
        aihubmix-mcp = sourceOnly packages.aihubmix-mcp;
        chatgpt-codex = sourceOnly packages.chatgpt-codex;
        cliproxyapi = packages.cliproxyapi.src;
        cliproxyapi-tool-shims = self.checks.${system}.cliproxyapi-tool-shims.patchedSource;
        cpa-manager-plus = packages.cpa-manager-plus.src;
        git-absorb = packages.git-absorb.patchedSource;
        git-branchless = sourceOnly packages.git-branchless;
        git-branchless-extraction = packages.git-branchless.patchedSource;
        git-revise = packages.git-revise.patchedSource;
        httpx2 = sourceOnly packages.mcp.httpx2;
        kimchi = packages.kimchi.patchedSource;
        kimchi-workflows = sourceOnly packages.kimchi-workflows;
        oxlint = packages.oxlint.src;
        semble = sourceOnly packages.semble;
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        ci-hestia = sourceOnly (import ../../dev/ci-hestia.nix {inherit inputs pkgs;});
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
