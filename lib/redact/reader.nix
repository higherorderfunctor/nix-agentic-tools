# The one reader. Arguments: the option label, then `<kind> <source>` pairs,
# where kind is literal, file or command. Each reference is read here, at
# launch, and the joined value goes to stdout only. Failures name the label and
# never the value or the command's output.
{pkgs}:
import ../strict-shell-application.nix pkgs {
  name = "redact-read";
  text = ''
    label=$1
    shift
    fail() { printf '%s: %s\n' "$label" "$1" >&2; exit 1; }
    joined=
    while (($#)); do
      kind=$1 source=$2
      shift 2
      value=
      case "$kind" in
        literal)
          joined+=$source
          continue
          ;;
        file)
          [[ ! -d "$source" ]] || fail 'reference is a directory'
          [[ -e "$source" ]] || fail 'reference file is missing'
          [[ -r "$source" ]] || fail 'reference file is unreadable'
          if IFS= read -r -d "" value <"$source"; then
            fail 'reference contains a NUL byte'
          fi
          ;;
        command)
          nul=0
          if IFS= read -r -d "" value < <("$source" 2>/dev/null); then nul=1; fi
          wait "$!" || fail 'reference command failed'
          [[ $nul == 0 ]] || fail 'reference contains a NUL byte'
          ;;
        *) fail 'invalid reference kind' ;;
      esac
      while [[ $value == *$'\n' ]]; do value=''${value%$'\n'}; done
      [[ -n "$value" ]] || fail 'reference resolved empty'
      joined+=$value
    done
    printf '%s' "$joined"
  '';
}
