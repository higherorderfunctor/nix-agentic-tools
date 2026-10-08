{pkgs}:
import ../strict-shell-application.nix pkgs {
  name = "redact-read";
  text = ''
    label=$1 source_kind=$2 source_path=$3
    fail() { printf '%s: %s\n' "$label" "$1" >&2; exit 1; }
    value=
    case "$source_kind" in
      file)
        [[ ! -d "$source_path" ]] || fail 'reference is a directory'
        [[ -e "$source_path" ]] || fail 'reference file is missing'
        [[ -r "$source_path" ]] || fail 'reference file is unreadable'
        if IFS= read -r -d "" value <"$source_path"; then
          fail 'reference contains a NUL byte'
        fi
        ;;
      command)
        nul=0
        if IFS= read -r -d "" value < <("$source_path" 2>/dev/null); then nul=1; fi
        wait $! || fail 'reference command failed'
        [[ $nul == 0 ]] || fail 'reference contains a NUL byte'
        ;;
      *) fail 'invalid reference source' ;;
    esac
    while [[ $value == *$'\n' ]]; do value=''${value%$'\n'}; done
    [[ -n "$value" ]] || fail 'reference resolved empty'
    printf '%s' "$value"
  '';
}
