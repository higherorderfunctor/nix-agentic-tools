pkgs: let
  trust = import ./projectTrust.nix pkgs;
in
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
      if [ -f "$user_config" ] && [ -r "$user_config" ]; then
        user_limit="$(top_level_limit "$user_config" 2>/dev/null || :)"
        if [[ "$user_limit" =~ ^[0-9]+$ ]] && [ "$user_limit" -gt "$effective" ]; then
          effective=$user_limit
        fi
      fi

      trusted="$(${pkgs.lib.getExe trust} "$directory")"
      project_config="$directory/.codex/config.toml"
      if [ "$trusted" = trusted ] && [ -f "$project_config" ] && [ -r "$project_config" ]; then
        project_limit="$(top_level_limit "$project_config" 2>/dev/null || :)"
        if [[ "$project_limit" =~ ^[0-9]+$ ]] && [ "$project_limit" -gt "$effective" ]; then
          effective=$project_limit
        fi
      fi

      printf '%s\n' "$effective"
    '';
  }
