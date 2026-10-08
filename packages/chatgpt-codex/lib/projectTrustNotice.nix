pkgs: let
  resolver = import ./effectiveProjectDocMaxBytes.nix pkgs;
in
  import ../../../lib/strict-shell-application.nix pkgs {
    name = "codex-project-trust-notice";
    text = ''
      project_config="$1/.codex/config.toml"
      user_config="''${CODEX_HOME:-''${HOME:-}/.codex}/config.toml"
      if [ -e "$user_config" ] && [ ! -r "$user_config" ]; then
        exit 0
      fi
      if [ -f "$project_config" ] && [ -r "$project_config" ]; then
        trusted="$(${pkgs.lib.getExe resolver} "$1" 32768 --trust 2>/dev/null || printf 'unknown\n')"
        if [ "$trusted" = untrusted ]; then
          printf 'warning: Codex ignores %s because this project is not trusted in %s. Set the project trust_level to trusted in the user config to load the delivered config.\n' "$project_config" "$user_config" >&2
        fi
      fi
      exit 0
    '';
  }
