{
  lib,
  pkgs,
  ...
}: let
  kimchi = pkgs.ai.kimchi;
in {
  checks = {
    # Copies only the two registration files: no Kimchi compile or dependency
    # build. The same exact substitutions run in Kimchi's postPatch phase.
    kimchi-workflows-source = pkgs.runCommand "kimchi-externalized-extensions-source-check" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.coreutils}/bin/mkdir -p src/resources
      ${pkgs.coreutils}/bin/cp ${kimchi.src}/src/cli.ts src/cli.ts
      ${pkgs.coreutils}/bin/cp ${kimchi.src}/src/resources/definitions.ts src/resources/definitions.ts
      ${pkgs.coreutils}/bin/chmod u+w src/cli.ts src/resources/definitions.ts
      ${kimchi.externalizeExtensions}
      rejectRegistration() {
        if ${pkgs.gnugrep}/bin/grep -F "$@" src/cli.ts src/resources/definitions.ts; then
          echo 'externalized code is still imported or registered' >&2
          exit 1
        else
          test "$?" -eq 1
        fi
      }
      # Pin the known registration independently of the substitution rows:
      # an empty externalization list must not leave the builtin factory or toggle.
      rejectRegistration -e '@kimchi-dev/kimchi-workflows/extension' -e 'extensions.workflows'
      ${lib.concatMapStrings (extension: ''
          rejectRegistration -e ${lib.escapeShellArg extension.id}
        '')
        kimchi.externalizedExtensions}
      echo PASS > "$out"
    '';
  };
}
