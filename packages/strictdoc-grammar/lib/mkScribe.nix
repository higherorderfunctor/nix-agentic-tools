# Scribe launchers share one interpreter and two explicit delivery modes.
# Installed mode pins implementation code in the store; Python owns document
# root selection (--root, SCRIBE_ROOT, cwd) and socket identity. Project mode
# retains live source lookup for this repository's semantics and board tooling.
# The selected document root never supplies code in installed mode.
{
  lib,
  pkgs,
  runner,
  sourceMode ? "installed",
  # Relative to dev/scripts in installed mode, or the project root in project mode.
  name ? "scribe",
  script ? "dev/scripts/scribe_cmd.py",
  description ? "Grammar-derived writer for this repository's .sdoc design graph",
}: let
  source = import ./scribeSource.nix {inherit lib;};
in
  pkgs.writeShellApplication {
    inherit name;

    # `nounset` has to be armed ABOVE writeShellApplication's own generated
    # `export PATH=...`, which is what putting these here rather than in `text`
    # buys: a PATH-less invocation fails loudly instead of yielding a
    # trailing-colon PATH, which bash reads as the current directory.
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];

    runtimeInputs = [pkgs.coreutils];

    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      ${lib.optionalString (sourceMode == "project") ''
        root=$PWD
        while [ ! -f "$root/strictdoc_config.py" ]; do
          parent=$(dirname "$root")
          if [ "$parent" = "$root" ]; then
            echo "${name}: no strictdoc_config.py in $PWD or any parent -- run" \
                 "inside the repository" >&2
            exit 1
          fi
          root=$parent
        done

        script=$root/${script}
        if [ ! -f "$script" ]; then
          echo "${name}: $script is missing; this wrapper carries the interpreter," \
               "not the script" >&2
          exit 1
        fi

      ''}
      ${lib.optionalString (sourceMode == "installed") ''
        script=${source}/${lib.removePrefix "dev/scripts/" script}
      ''}
      exec ${lib.getExe runner} "$script" "$@"
    '';

    meta = {
      inherit description;
      mainProgram = name;
      license = lib.licenses.unlicense;
      platforms = lib.platforms.unix;
    };
  }
