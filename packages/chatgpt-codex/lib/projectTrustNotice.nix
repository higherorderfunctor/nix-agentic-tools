pkgs: let
  trust = import ./projectTrust.nix pkgs;
in
  import ../../../lib/strict-shell-application.nix pkgs {
    name = "codex-project-trust-notice";
    text = ''
      project_config="$1/.codex/config.toml"
      if [ -f "$project_config" ] && [ -r "$project_config" ]; then
        trusted="$(${pkgs.lib.getExe trust} "$1")"
        if [ "$trusted" = untrusted ]; then
          printf 'warning: Codex ignores %s because this project is not trusted in %s. Set the effective project trust entry to trusted in the user config; an explicit cwd entry overrides main-checkout trust.\n' "$project_config" "''${CODEX_HOME:-''${HOME:-}/.codex}/config.toml" >&2
        fi
      fi
      exit 0
    '';
  }
