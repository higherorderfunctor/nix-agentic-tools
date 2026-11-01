# cspell:ignore ASKPASS refspecs unconfigured
# Agents push to git://<listen>:<port>/<repository>.git. The daemon forwards
# through a per-repository SSH credential resolved from GIT_RELAY_CONFIG at
# every push; the hook refuses the receive when that atomic forward fails.
{
  openssh ? pkgs.openssh,
  pkgs,
  strictShellApplication,
  ...
}: let
  inherit (pkgs) lib;
  strict = strictShellApplication pkgs;
  upstreamUrl = import ../../../../lib/upstream.nix {inherit lib;};

  # receive-pack runs this hook in quarantine: only upstream writes refs.
  preReceive = strict {
    name = "pre-receive";
    runtimeInputs = [pkgs.git pkgs.jq openssh];
    text = ''
      refspecs=()
      while read -r _ new ref; do
        if [[ $new =~ ^0+$ ]]; then
          refspecs+=(":$ref")
        else
          refspecs+=("+$new:$ref")
        fi
      done
      ((''${#refspecs[@]})) || exit 0
      # A repository the launcher did not configure cannot forward pushes.
      if ! upstream=$(git config --get relay.upstream) ||
        ! credential=$(git config --get relay.credential) ||
        ! known_hosts=$(git config --get relay.knownHosts); then
        echo "git-relay: missing relay upstream, credential or knownHosts; push refused" >&2
        exit 1
      fi
      # Removing this credential from the current config revokes existing repos.
      key=$(jq -er --arg credential "$credential" \
        '.credentials[$credential].sshKeyFile | select(type == "string" and length > 0)' \
        "$GIT_RELAY_CONFIG") || {
        echo "git-relay: credential '$credential' absent or missing sshKeyFile in current config; push refused" >&2
        exit 1
      }
      # OpenSSH parses this option again as a file list; quotes preserve spaces
      # and escaped quotes/backslashes keep the runtime path one pin file.
      known_hosts=''${known_hosts//\\/\\\\}
      known_hosts=''${known_hosts//\"/\\\"}
      # IdentityFile=none refuses default keys if SSH drops an unreadable -i path.
      # Refuse SSH config, agents, prompts and host files outside this repo's pins.
      options=(-F none -i "$key" -o IdentityFile=none -o IdentitiesOnly=yes -o IdentityAgent=none
        -o BatchMode=yes -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=\"$known_hosts\"" -o GlobalKnownHostsFile=/dev/null)
      GIT_SSH_COMMAND="${lib.getExe' openssh "ssh"} $(printf '%q ' "''${options[@]}")"
      export GIT_SSH_COMMAND
      # Refuses an inherited transport allowlist and any non-SSH rewrite of the
      # validated upstream.
      export GIT_ALLOW_PROTOCOL=ssh
      # --no-verify refuses an inherited pre-push hook; refspecs pass through.
      if ! git push --atomic --no-verify "$upstream" "''${refspecs[@]}"; then
        echo "git-relay: forward to $upstream failed; push refused" >&2
        exit 1
      fi
    '';
  };
  hooks = pkgs.linkFarm "git-relay-hooks" [
    {
      name = "pre-receive";
      path = lib.getExe preReceive;
    }
  ];
in
  strict {
    name = "git-relay";
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.jq];
    text = ''
      # Refuse host config and injected command-scope config for init, daemon,
      # receive-pack and hooks alike; GIT_CONFIG also redirects `git config` writes.
      export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
      unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
      for variable in "''${!GIT_CONFIG_KEY_@}" "''${!GIT_CONFIG_VALUE_@}"; do
        unset "$variable"
      done
      # Refuse caller repository/object paths that override init or git -C.
      unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_DIR GIT_INDEX_FILE
      unset GIT_NAMESPACE GIT_OBJECT_DIRECTORY GIT_SHALLOW_FILE GIT_WORK_TREE
      # No inherited transport command, prompt helper or agent may select a key.
      unset GIT_SSH_COMMAND GIT_SSH GIT_SSH_VARIANT GIT_ASKPASS SSH_ASKPASS SSH_AUTH_SOCK
      config=''${GIT_RELAY_CONFIG:?GIT_RELAY_CONFIG must name the JSON config file}
      root=$PWD/repositories
      pins=$PWD/known_hosts.d
      # --strict-paths requires an explicit served directory; empty configs fail.
      names=$(jq -r '.repositories | keys[]' "$config")
      [[ -n $names ]] || { echo "git-relay: no repositories configured" >&2; exit 1; }
      mkdir -p "$root" "$pins"
      hosts=$(jq -r '.forges | keys[]' "$config")
      host_pattern=${lib.escapeShellArg "^${upstreamUrl.hostPattern}$"}
      while IFS= read -r host; do
        # Forge names become filenames; refuse path separators and dot aliases.
        [[ $host =~ $host_pattern ]] || { echo "git-relay: invalid forge host '$host'" >&2; exit 1; }
        jq -er --arg host "$host" '.forges[$host].hostKeys | select(type == "string" and test("[^[:space:]]"))' \
          "$config" >"$pins/$host"
      done <<<"$hosts"
      ssh_pattern=${lib.escapeShellArg "^${upstreamUrl.sshPattern}$"}
      scp_pattern=${lib.escapeShellArg "^${upstreamUrl.scpPattern}$"}
      served=()
      while IFS= read -r name; do
        # A direct JSON caller cannot escape the served repository directory.
        [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || {
          echo "git-relay: invalid repository name '$name'" >&2; exit 1;
        }
        upstream=$(jq -er --arg name "$name" '.repositories[$name].upstream' "$config")
        if [[ $upstream =~ $ssh_pattern ]]; then
          host=''${BASH_REMATCH[2]}
        elif [[ $upstream != *://* && $upstream =~ $scp_pattern ]]; then
          host=''${BASH_REMATCH[2]}
        else
          echo "git-relay: repository '$name': upstream must use SSH (ssh:// or [user@]host:path)" >&2
          exit 1
        fi
        # An absent forge must never fall back to the daemon user's known_hosts.
        jq -e --arg host "$host" '.forges | has($host)' "$config" >/dev/null &&
          [[ -s $pins/$host ]] || { echo "git-relay: repository '$name': no forge pins for '$host'" >&2; exit 1; }
        credential=$(jq -er --arg name "$name" '.repositories[$name].credential' "$config")
        jq -e --arg credential "$credential" \
          '.credentials[$credential].sshKeyFile | type == "string" and length > 0' "$config" >/dev/null || {
          echo "git-relay: repository '$name': credential '$credential' missing sshKeyFile" >&2; exit 1;
        }
        repo=$root/$name.git
        # Empty templates refuse host hooks; isolated init uses Git's built-in HEAD default.
        [[ -d $repo ]] || git init --bare --template= --quiet "$repo"
        # Refuse repository-provided hooks in favor of the forwarding hook.
        git -C "$repo" config core.hooksPath ${hooks}
        # The forward refuses client-supplied destinations, keys and trust files.
        git -C "$repo" config relay.credential "$credential"
        git -C "$repo" config relay.knownHosts "$pins/$host"
        git -C "$repo" config relay.upstream "$upstream"
        # Push options are not forwarded; refuse to advertise their acceptance.
        git -C "$repo" config receive.advertisePushOptions false
        # Refuse malformed received objects before forwarding them upstream.
        git -C "$repo" config receive.fsckObjects true
        # Upstream-approved deletes, including HEAD, must not be refused locally.
        git -C "$repo" config receive.denyDeleteCurrent ignore
        git -C "$repo" config receive.denyDeletes false
        # Upstream-approved force pushes must not be refused locally.
        git -C "$repo" config receive.denyNonFastForwards false
        served+=("$repo")
      done <<<"$names"

      # Explicit strict paths refuse unconfigured and stale repos; export-all
      # serves these paths without trusting a git-daemon-export-ok marker.
      listen=$(jq -er .listen "$config")
      port=$(jq -er .port "$config")
      exec git daemon --reuseaddr --listen="$listen" --port="$port" \
        --base-path="$root" --strict-paths --export-all --enable=receive-pack --informative-errors \
        "''${served[@]}"
    '';
  }
