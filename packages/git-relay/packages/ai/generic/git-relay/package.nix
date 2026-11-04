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

  # The forward and the access hook's refresh reach a repository's upstream
  # one way: its configured upstream, the key its credential names in the
  # current config, and SSH held to that key and the forge's pins. Each caller
  # defines refuse for the channel its refusal reaches the client on.
  upstreamTransport = ''
    # A repository the launcher did not configure cannot reach an upstream.
    if ! upstream=$(git config --get relay.upstream) ||
      ! credential=$(git config --get relay.credential) ||
      ! known_hosts=$(git config --get relay.knownHosts); then
      refuse "missing relay upstream, credential or knownHosts"
    fi
    # Removing this credential from the current config revokes existing repos.
    key=$(jq -er --arg credential "$credential" \
      '.credentials[$credential].sshKeyFile | select(type == "string" and length > 0)' \
      "$GIT_RELAY_CONFIG") ||
      refuse "credential '$credential' absent or missing sshKeyFile in current config"
    # OpenSSH parses this option again as a file list: the quotes keep a state
    # directory ($PWD) with spaces one path, and escaping " and \ keeps a $PWD
    # containing either from ending that quoted path early.
    known_hosts=''${known_hosts//\\/\\\\}
    known_hosts=''${known_hosts//\"/\\\"}
    # IdentityFile=none refuses default keys when SSH drops an unreadable -i
    # path; the missing-key case in checks/forward.nix shows it.
    # Refuse SSH config, agents, prompts and host files outside this repo's pins.
    options=(-F none -i "$key" -o IdentityFile=none -o IdentitiesOnly=yes -o IdentityAgent=none
      -o BatchMode=yes -o StrictHostKeyChecking=yes
      -o "UserKnownHostsFile=\"$known_hosts\"" -o GlobalKnownHostsFile=/dev/null)
    GIT_SSH_COMMAND="${lib.getExe' openssh "ssh"} $(printf '%q ' "''${options[@]}")"
    export GIT_SSH_COMMAND
    # Refuses an inherited transport allowlist and any non-SSH rewrite of the
    # validated upstream.
    export GIT_ALLOW_PROTOCOL=ssh
  '';

  # git daemon runs this before every request with the service and the
  # repository path. Refreshing a push's repository from upstream makes the
  # client's fast-forward check, and the forward's lease, compare against the
  # forge's current refs rather than whatever the relay last forwarded.
  accessHook = strict {
    name = "git-relay-access";
    runtimeInputs = [pkgs.git pkgs.jq openssh];
    text = ''
      [[ $1 == receive-pack ]] || exit 0
      export GIT_DIR=$2
      # git daemon sends one stdout line to the client when this hook declines.
      refuse() {
        echo "git-relay: $1; push refused"
        exit 1
      }
      ${upstreamTransport}
      # Fetch output goes to the daemon's log, never to the client.
      git fetch --quiet --prune --no-tags "$upstream" \
        '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' >&2 ||
        refuse "refresh from $upstream failed"
    '';
  };

  # receive-pack runs this hook in quarantine: only upstream writes refs.
  preReceive = strict {
    name = "pre-receive";
    runtimeInputs = [pkgs.git pkgs.jq openssh];
    text = ''
      refspecs=()
      leases=()
      while read -r old new ref; do
        # Each ref overwrites or deletes only the value the relay advertised, so
        # an upstream that moved after the access hook's refresh refuses the
        # forward instead of losing commits; the client's own --force passes.
        leases+=("--force-with-lease=$ref:$old")
        if [[ $new =~ ^0+$ ]]; then
          refspecs+=(":$ref")
        else
          refspecs+=("$new:$ref")
        fi
      done
      ((''${#refspecs[@]})) || exit 0
      refuse() {
        echo "git-relay: $1; push refused" >&2
        exit 1
      }
      ${upstreamTransport}
      # receive-pack relays this hook's output to the pusher, and OpenSSH names
      # the key file in its errors. The push's output goes to descriptor 3, the
      # daemon's own stderr, so the client reads only the fixed line below.
      # --no-verify refuses an inherited pre-push hook.
      if ! git push --atomic --no-verify "''${leases[@]}" "$upstream" "''${refspecs[@]}" >&3 2>&3; then
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
      # The git protocol has no authentication, so the daemon serves only the
      # local machine: a JSON caller cannot bind it to a reachable address.
      listen=$(jq -er .listen "$config")
      [[ $listen =~ ^127(\.[0-9]{1,3}){3}$ || $listen == ::1 ]] || {
        echo "git-relay: refusing non-loopback listen address '$listen'" >&2
        exit 1
      }
      root=$PWD/repositories
      pins=$PWD/known_hosts.d
      # --strict-paths requires an explicit served directory; empty configs fail.
      names=$(jq -r '.repositories | keys[]' "$config")
      [[ -n $names ]] || { echo "git-relay: no repositories configured" >&2; exit 1; }
      mkdir -p "$root" "$pins"
      hosts=$(jq -r '.forges | keys[]' "$config")
      host_pattern=${lib.escapeShellArg "^${upstreamUrl.hostPattern}$"}
      name_pattern=${lib.escapeShellArg "^${upstreamUrl.repositoryNamePattern}$"}
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
        [[ $name =~ $name_pattern ]] || {
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
      port=$(jq -er .port "$config")
      # The pre-receive hook writes forward output here, never to the client.
      exec 3>&2
      exec git daemon --reuseaddr --listen="$listen" --port="$port" \
        --base-path="$root" --strict-paths --export-all --enable=receive-pack --informative-errors \
        --access-hook=${lib.getExe accessHook} \
        "''${served[@]}"
    '';
  }
