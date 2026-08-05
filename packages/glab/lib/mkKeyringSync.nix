# Builds the Linux Home Manager one-shot that copies a runtime credential into
# glab's OS-keyring storage. The caller owns lifecycle wiring (activation marker,
# graphical-session path unit); this helper owns secret flow and the glab argv.
{
  cfg,
  configDir,
  lib,
  pendingFile,
  pkgs,
}: let
  credentialsLib = import ../../../lib/credentials.nix {inherit lib;};

  hostAssignment = credentialsLib.mkSecretAssignment pkgs "glab_sync_host" cfg.host;
  tokenAssignment = credentialsLib.mkSecretAssignment pkgs "glab_sync_token" cfg.token;

  apiHost = cfg.settings.api_host or null;
  apiProtocol = cfg.settings.api_protocol or null;
  gitProtocol = cfg.settings.git_protocol or null;
  sshHost = cfg.settings.ssh_host or null;

  optionalLoginArg = flag: value:
    lib.optionalString (value != null) ''
      glab_sync_args+=(${lib.escapeShellArg flag} ${lib.escapeShellArg value})'';

  scriptText = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    umask 077
    glab_sync_probe_stored=false

    glab_sync_cleanup() {
      ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg pendingFile}
      if [ "$glab_sync_probe_stored" = true ]; then
        ${pkgs.libsecret}/bin/secret-tool clear service glab-keyring-sync-probe \
          >/dev/null 2>&1 || :
      fi
    }
    trap glab_sync_cleanup EXIT
    trap 'exit 1' HUP INT TERM

    # A cancelled/unavailable Secret Service must fail BEFORE the real token is
    # read. glab otherwise deliberately falls back to plaintext config storage
    # when no keyring backend is available.
    printf '%s' probe \
      | ${pkgs.libsecret}/bin/secret-tool store \
          --label='glab keyring availability probe' \
          service glab-keyring-sync-probe \
          >/dev/null
    glab_sync_probe_stored=true
    ${pkgs.libsecret}/bin/secret-tool clear service glab-keyring-sync-probe \
      >/dev/null 2>&1 || :
    glab_sync_probe_stored=false

    ${hostAssignment}
    ${tokenAssignment}

    glab_sync_api_protocol=${lib.escapeShellArg (
      if apiProtocol == null
      then ""
      else apiProtocol
    )}
    if [ -z "$glab_sync_api_protocol" ]; then
      case "$glab_sync_host" in
        http://*) glab_sync_api_protocol=http ;;
        *) glab_sync_api_protocol=https ;;
      esac
    fi

    glab_sync_host="''${glab_sync_host#*://}"
    glab_sync_host="''${glab_sync_host%/}"
    if [ -z "$glab_sync_host" ]; then
      echo "glab keyring sync: host is empty after removing its URL scheme" >&2
      exit 1
    fi

    glab_sync_config_dir=${lib.escapeShellArg configDir}
    ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$glab_sync_config_dir"
    if [ ! -w "$glab_sync_config_dir" ] || [ ! -x "$glab_sync_config_dir" ]; then
      echo "glab keyring sync: config directory $glab_sync_config_dir is not writable and searchable (need w+x)" >&2
      exit 1
    fi
    if [ -f "$glab_sync_config_dir/config.yml" ]; then
      glab_sync_config_mode="$(${pkgs.coreutils}/bin/stat -c '%a' "$glab_sync_config_dir/config.yml")"
      if [ "$glab_sync_config_mode" != 600 ]; then
        ${pkgs.coreutils}/bin/chmod 600 "$glab_sync_config_dir/config.yml"
      fi
    fi

    # auth login treats CI as a reason to choose plaintext storage and token
    # environment variables override stdin/stored credentials. This service is
    # intentionally neither: keep only the Secret Service session environment.
    unset CI GITLAB_ACCESS_TOKEN GITLAB_CI GITLAB_JOB_TOKEN GITLAB_TOKEN OAUTH_TOKEN
    GLAB_CONFIG_DIR="$glab_sync_config_dir"
    export GLAB_CONFIG_DIR

    glab_sync_args=(
      auth login
      --api-protocol "$glab_sync_api_protocol"
      --hostname "$glab_sync_host"
      --stdin
      # Deprecated by current glab, but retained so older package overrides
      # cannot silently choose plaintext storage.
      --use-keyring
    )
    ${optionalLoginArg "--api-host" apiHost}
    ${optionalLoginArg "--git-protocol" gitProtocol}
    ${optionalLoginArg "--ssh-hostname" sshHost}

    printf '%s' "$glab_sync_token" \
      | "${lib.getExe cfg.package}" "''${glab_sync_args[@]}"
    unset glab_sync_token
  '';

  script = pkgs.writeShellScript "glab-keyring-sync" scriptText;
in {
  inherit script scriptText;
}
