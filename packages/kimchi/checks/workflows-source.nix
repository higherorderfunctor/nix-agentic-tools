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
      ${lib.concatMapStrings (extension: ''
          if ${pkgs.gnugrep}/bin/grep -F ${lib.escapeShellArg extension.id} src/cli.ts src/resources/definitions.ts; then
            echo 'externalized resource is still registered' >&2
            exit 1
          fi
        '')
        kimchi.externalizedExtensions}
      echo PASS > "$out"
    '';
  };
}
