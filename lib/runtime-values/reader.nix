{pkgs}:
pkgs.writeShellApplication {
  name = "runtime-value-read";
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :
    label=$1 source_kind=$2 source_path=$3
    fail() { printf '%s: %s\n' "$label" "$1" >&2; exit 1; }
    umask 077
    temp=
    trap 'if [[ -n "$temp" ]]; then ${pkgs.coreutils}/bin/rm -- "$temp"; fi' EXIT
    case "$source_kind" in
      file)
        [[ ! -d "$source_path" ]] || fail 'reference is a directory'
        [[ -e "$source_path" ]] || fail 'reference file is missing'
        [[ -r "$source_path" ]] || fail 'reference file is unreadable'
        ;;
      helper)
        temp=$(${pkgs.coreutils}/bin/mktemp)
        if ! "$source_path" >"$temp" 2>/dev/null; then fail 'reference helper failed'; fi
        source_path=$temp
        ;;
      *) fail 'invalid reference source' ;;
    esac
    value=
    if IFS= read -r -d "" value <"$source_path" 2>/dev/null; then
      fail 'reference contains a NUL byte'
    fi
    [[ -n "$value" ]] || fail 'reference resolved empty'
    printf '%s' "$value"
  '';
}
