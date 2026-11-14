# Check built outputs for patch artifacts; the helper checks source boundaries.
{
  inputs,
  packageLib,
  pkgs,
  self,
  ...
}: {
  checks.patch-artifacts = let
    inherit (pkgs) lib;
    system = pkgs.stdenv.hostPlatform.system;
    packages = self.ciPackages.${system};
    patching = packageLib.patching {inherit pkgs;};
    # Historical flags on the real pinned source reproduce the config backup.
    baseline = pkgs.runCommand "cliproxyapi-backup-baseline" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cp -R ${packages.cliproxyapi.src.src} "$out"
      chmod -R u+w "$out"
      cd "$out"
      for patchFile in ${lib.escapeShellArgs packages.cliproxyapi.src.patches}; do
        patch -p1 --fuzz=0 < "$patchFile"
      done
      test -f config.example.yaml.orig
    '';
    outputs =
      lib.getAttrs [
        "aihubmix-mcp"
        "chatgpt-codex"
        "cliproxyapi"
        "cpa-manager-plus"
        "git-absorb"
        "git-branchless"
        "git-revise"
        "kimchi"
        "kimchi-workflows"
        "oxlint"
        "semble"
        # Its unchanged nixpkgs patch phase is outside owned applications.
        "tsgolint"
      ]
      packages
      // {inherit (packages.mcp) httpx2;}
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        ci-hestia = import ../../dev/ci-hestia.nix {inherit inputs pkgs;};
      };
  in
    pkgs.runCommand "patch-artifacts" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir "$out"
      test -f ${baseline}/config.example.yaml.orig
      if (
        ${patching.validate (lib.escapeShellArg baseline)}
      ) > baseline.log 2>&1; then
        echo 'historical offset backup escaped validation' >&2
        exit 1
      fi
      grep -F '${baseline}/config.example.yaml.orig' baseline.log
      cp baseline.log "$out/baseline-refusal"
      mkdir -p nested/inner
      ln -s "$PWD/nested" linked
      for suffix in orig rej; do
        touch "nested/inner/leaked.$suffix"
        if (
          ${patching.validate "linked"}
        ) > nested.log 2>&1; then
          echo "nested $suffix escaped validation" >&2
          exit 1
        fi
        grep -F "linked/inner/leaked.$suffix" nested.log
        cp nested.log "$out/nested-$suffix-refusal"
        rm "nested/inner/leaked.$suffix"
      done
      touch nested/inner/unrelated
      ${patching.validate "linked"}
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: package:
        lib.concatMapStringsSep "\n" (output: let
          path = lib.getOutput output package;
        in ''
          echo "patch-artifacts: ${name}.${output} (${path})"
          ${patching.validate (lib.escapeShellArg path)}
          ln -s ${path} "$out/${name}.${output}"
        '')
        package.outputs)
      outputs)}
    '';
}
