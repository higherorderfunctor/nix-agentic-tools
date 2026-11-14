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
        kimchi-command-shell = self.checks.${system}.kimchi-command-shell;
        kimchi-package-identity = "${self.checks.${system}.kimchi-package-identity}/identity-source";
        kimchi-workflows = sourceOnly packages.kimchi-workflows;
        oxlint = packages.oxlint.src;
        oxlint-napi-patch = self.checks.${system}.oxlint-napi-patch;
        semble = sourceOnly packages.semble;
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        ci-hestia = sourceOnly (import ../../dev/ci-hestia.nix {inherit inputs pkgs;});
        kimchi-codeql = packages.kimchi.codeql.source;
      };
    dependencies = {
      kimchi-package-identity-dependencies = {
        patchedDependencies = lib.escapeShellArg packages.kimchi.patchedDependencies;
        source = self.checks.${system}.kimchi-package-identity;
      };
      kimchi-workflows-toolchain = {
        directory = "node_modules/.runtime";
        layout = "runtime";
        patchedDependencies = lib.escapeShellArg packages.kimchi.patchedDependencies;
        source = packages.kimchi-workflows.toolchain;
      };
      oxlint-napi-materialization = {
        patchedDependencies = ''<(${pkgs.yq-go}/bin/yq -o=json '.patchedDependencies' ${packages.oxlint.src}/pnpm-workspace.yaml)'';
        source = self.checks.${system}.oxlint-napi-materialization;
      };
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
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: args: ''
          ln -s ${args.source} "$out/${name}"
          echo "patch-sources: ${name} (${args.source})"
          ${(packageLib.patching {inherit pkgs;}).validateDependencies ((removeAttrs args ["source" "directory"])
            // {
              directory = "${args.source}/${args.directory or "node_modules/.pnpm"}";
            })}
        '')
        dependencies)}
    '';
}
