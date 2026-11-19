# Runs pr-watch-resource.mjs against the release tree, where pr-watch has no
# resource and loads by default, and against patchedSource, where
# remote-feature-toggles.patch keeps it off until the resource is enabled.
{pkgs, ...}: let
  inherit (pkgs.ai.kimchi.passthru) extractionSources patchedSource;
  patch = ../packages/ai/kimchi/remote-feature-toggles.patch;
in {
  checks.kimchi-pr-watch-resource = assert builtins.elem patch patchedSource.patches;
    pkgs.runCommand "kimchi-pr-watch-resource" {
      nativeBuildInputs = [pkgs.nodejs];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      if node --experimental-vm-modules ${./pr-watch-resource.mjs} ${extractionSources.kimchi} > pristine.log 2>&1; then
        echo 'unpatched source unexpectedly keeps pr-watch off; reassess the patch' >&2
        exit 1
      fi
      grep -q 'AssertionError' pristine.log
      node --experimental-vm-modules ${./pr-watch-resource.mjs} ${patchedSource}
      echo PASS > "$out"
    '';
}
