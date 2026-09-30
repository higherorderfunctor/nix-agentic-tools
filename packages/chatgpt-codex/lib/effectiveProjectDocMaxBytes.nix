pkgs:
import ../../../lib/strict-shell-application.nix pkgs {
  name = "codex-effective-project-doc-max-bytes";
  text = ''
    if [ "$#" -ne 2 ]; then
      echo "usage: codex-effective-project-doc-max-bytes DIRECTORY DEFAULT_BYTES" >&2
      exit 2
    fi
    directory=$1
    effective=$2
    user_config="''${CODEX_HOME:-$HOME/.codex}/config.toml"

    top_level_limit() {
      ${pkgs.gawk}/bin/awk '
        /^[[:space:]]*\[/ { exit }
        match($0, /^[[:space:]]*project_doc_max_bytes[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*(#.*)?$/, value) {
          print value[1]
          exit
        }
      ' "$1"
    }

    user_limit=""
    if [ -f "$user_config" ]; then
      user_limit="$(top_level_limit "$user_config")"
      if [[ "$user_limit" =~ ^[0-9]+$ ]] && [ "$user_limit" -gt "$effective" ]; then
        effective=$user_limit
      fi
    fi

    common_dir="$(${pkgs.git}/bin/git -C "$directory" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || :)"
    if [ -n "$common_dir" ] && [ -f "$user_config" ]; then
      main_checkout="$(${pkgs.coreutils}/bin/dirname "$common_dir")"
      trusted="$(${pkgs.gawk}/bin/awk -v header="[projects.\"$main_checkout\"]" '
        $0 == header { inside = 1; next }
        /^[[:space:]]*\[/ { inside = 0 }
        inside && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"trusted"[[:space:]]*(#.*)?$/ {
          print "yes"
          exit
        }
      ' "$user_config")"
      project_config="$directory/.codex/config.toml"
      if [ "$trusted" = yes ] && [ -f "$project_config" ]; then
        project_limit="$(top_level_limit "$project_config")"
        if [[ "$project_limit" =~ ^[0-9]+$ ]] && [ "$project_limit" -gt "$effective" ]; then
          effective=$project_limit
        fi
      fi
    fi

    printf '%s\n' "$effective"
  '';
}
