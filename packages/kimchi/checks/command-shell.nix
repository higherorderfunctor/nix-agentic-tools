{
  lib,
  pkgs,
  ...
}: let
  kimchi = pkgs.ai.kimchi;
  patch = ../packages/ai/kimchi/command-shell.patch;
in {
  checks.kimchi-command-shell = assert builtins.elem patch kimchi.patches;
    pkgs.runCommand "kimchi-command-shell" {
      nativeBuildInputs = [pkgs.gnupatch pkgs.nodejs];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p src/extensions/bash-background
      cp ${kimchi.src}/src/extensions/bash-background/{index,bash-background-tool}.ts src/extensions/bash-background/
      chmod u+w src/extensions/bash-background/*.ts
      if node --experimental-vm-modules ${./command-shell.mjs} . > pristine.log 2>&1; then
        echo 'unpatched source unexpectedly honors shellPath; reassess the patch' >&2
        exit 1
      fi
      grep -q 'AssertionError' pristine.log
      patch ${lib.escapeShellArgs kimchi.patchFlags} < ${patch}
      node --experimental-vm-modules ${./command-shell.mjs} .
      echo PASS > "$out"
    '';
}
