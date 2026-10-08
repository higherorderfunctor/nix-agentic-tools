pkgs:
import ../strict-shell-application.nix pkgs {
  name = "ai-runtime-path-provenance-notice";
  text = ''
    runtime=$1
    resolved=$2
    profile=$3
    expected="$profile/bin/$runtime"
    if [ -n "$profile" ] && [ -n "$resolved" ] && [ -e "$resolved" ] && [ -e "$expected" ]; then
      actual="$(${pkgs.coreutils}/bin/readlink -f "$resolved" 2>/dev/null || :)"
      wanted="$(${pkgs.coreutils}/bin/readlink -f "$expected" 2>/dev/null || :)"
      if [ -n "$actual" ] && [ -n "$wanted" ] && [ "$actual" != "$wanted" ]; then
        printf 'warning: %s on PATH is %s, not the devenv profile copy %s. Put the devenv profile before user-global installs on PATH.\n' "$runtime" "$resolved" "$expected" >&2
      fi
    fi
    exit 0
  '';
}
