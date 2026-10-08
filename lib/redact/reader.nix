{pkgs}:
import ../strict-shell-application.nix pkgs {
  name = "redact-read";
  text = ''
    label=$1 source_kind=$2 source_path=$3
    fail() { printf '%s: %s\n' "$label" "$1" >&2; exit 1; }
    umask 077
    temp=$(${pkgs.coreutils}/bin/mktemp)
    trap '${pkgs.coreutils}/bin/rm -- "$temp"' EXIT
    case "$source_kind" in
      file)
        [[ ! -d "$source_path" ]] || fail 'reference is a directory'
        [[ -e "$source_path" ]] || fail 'reference file is missing'
        [[ -r "$source_path" ]] || fail 'reference file is unreadable'
        # Snapshot catches read errors (including a file removed after the test).
        if ! ${pkgs.coreutils}/bin/cat -- "$source_path" >"$temp" 2>/dev/null; then
          fail 'reference file could not be read'
        fi
        ;;
      command)
        if ! "$source_path" >"$temp" 2>/dev/null; then
          fail 'reference command failed'
        fi
        ;;
      *) fail 'invalid reference source' ;;
    esac
    value=
    if IFS= read -r -d "" value <"$temp"; then
      fail 'reference contains a NUL byte'
    fi
    while [[ $value == *$'\n' ]]; do value=''${value%$'\n'}; done
    [[ -n "$value" ]] || fail 'reference resolved empty'
    printf '%s' "$value"
  '';
}
