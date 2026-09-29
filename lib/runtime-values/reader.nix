# cspell:ignore libiconv
{pkgs}:
pkgs.writeShellApplication {
  name = "runtime-value-read";
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :
    label=$1 source_kind=$2 source_path=$3 newline=$4 prefix=$5 suffix=$6
    validation="''${7:-str}"
    if [[ "$#" -ge 7 ]]; then shift 7; else shift 6; fi
    fail() { printf '%s: %s\n' "$label" "$1" >&2; exit 1; }
    umask 077
    temp=
    trap 'if [[ -n "$temp" ]]; then ${pkgs.coreutils}/bin/rm -f -- "$temp"; fi' EXIT
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
    # read -d NUL retains every newline and also detects unsupported NUL bytes.
    value=
    if IFS= read -r -d "" value <"$source_path" 2>/dev/null; then
      fail 'reference contains a NUL byte'
    fi
    if ! printf '%s' "$value" | ${
      if pkgs.stdenv.hostPlatform.isLinux
      then pkgs.glibc.bin
      else pkgs.libiconv
    }/bin/iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
      fail 'reference is not UTF-8'
    fi
    case "$newline" in
      strip-final-lf) value="''${value%$'\n'}" ;;
      preserve) ;;
      *) fail 'invalid newline policy' ;;
    esac
    [[ -n "$value" ]] || fail 'reference resolved empty'
    if [[ "$validation" != str && ( -n "$prefix" || -n "$suffix" ) ]]; then
      fail 'decoration requires a string schema'
    fi
    case "$validation" in
      str) ;;
      bool) [[ "$value" == true || "$value" == false ]] || fail 'reference is not a boolean string' ;;
      int) [[ "$value" =~ ^-?[0-9]+$ ]] || fail 'reference is not an integer string' ;;
      float) [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || fail 'reference is not a number string' ;;
      strMatching)
        [[ "$value" =~ ^($1)$ ]] || fail 'reference does not match its string pattern'
        ;;
      enum)
        valid=false
        for candidate in "$@"; do
          if [[ "$value" == "$candidate" ]]; then valid=true; break; fi
        done
        [[ "$valid" == true ]] || fail 'reference is not an allowed enum value'
        ;;
      *) fail 'unsupported runtime schema' ;;
    esac
    printf '%s%s%s' "$prefix" "$value" "$suffix"
  '';
}
