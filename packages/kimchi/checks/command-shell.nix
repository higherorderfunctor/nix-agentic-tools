{
  packageLib,
  pkgs,
  ...
}: let
  patching = packageLib.patching {inherit pkgs;};
  # The release tree proves the unpatched failure; patchedSource carries the patch.
  inherit (pkgs.ai.kimchi.passthru) extractionSources patchedSource;
  patch = ../packages/ai/kimchi/command-shell.patch;
in {
  checks.kimchi-command-shell = assert builtins.elem patch patchedSource.patches;
    pkgs.runCommand "kimchi-command-shell" {
      nativeBuildInputs = [pkgs.nodejs];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p src/extensions/bash-background
      cp ${extractionSources.kimchi}/src/extensions/bash-background/{index,bash-background-tool}.ts src/extensions/bash-background/
      chmod u+w src/extensions/bash-background/*.ts
      if node --experimental-vm-modules ${./command-shell.mjs} . > pristine.log 2>&1; then
        echo 'unpatched source unexpectedly honors shellPath; reassess the patch' >&2
        exit 1
      fi
      grep -q 'AssertionError' pristine.log
      ${patching.command {patchFiles = [patch];}}
      node --experimental-vm-modules ${./command-shell.mjs} .
      ${patching.validate "."}
      touch "$out"
    '';
}
