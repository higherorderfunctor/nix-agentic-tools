# cspell:ignore ASKPASS refspecs unconfigured urandom
# Agents push to git://<listen>:<port>/<repository>.git. The daemon forwards
# through a per-repository SSH credential resolved from GIT_RELAY_CONFIG at
# every push; the hook refuses the receive when that atomic forward fails.
# `session open|close|gc` manage per-session repositories a session-only
# daemon serves; session subcommands run from the daemon's state directory.
{
  openssh ? pkgs.openssh,
  pkgs,
  strictShellApplication,
  ...
}: let
  inherit (pkgs) lib;
  strict = strictShellApplication pkgs;
  upstreamUrl = import ../../../../lib/upstream.nix {inherit lib;};
  # One rule the hook, the daemon's start check and `session open` share: the
  # credential must exist with a key and currently allow the repository's
  # upstream host, so removing either revokes pushes without touching the
  # repository on disk. `arrays` refuses a missing or non-list allowlist.
  credentialAllowed = ''
    .credentials[$credential]
    | select((.sshKeyFile | type == "string" and length > 0) and (.forges | arrays | index($host)))
    | .sshKeyFile
  '';

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
        ! host=$(git config --get relay.host) ||
        ! credential=$(git config --get relay.credential) ||
        ! known_hosts=$(git config --get relay.knownHosts); then
        echo "git-relay: missing relay upstream, host, credential or knownHosts; push refused" >&2
        exit 1
      fi
      # Removing this credential, or its permission for this upstream host,
      # from the current config revokes this repository's next push.
      key=$(jq -er --arg credential "$credential" --arg host "$host" \
        '${credentialAllowed}' "$GIT_RELAY_CONFIG") || {
        echo "git-relay: credential '$credential' absent, keyless, or not allowed for '$host'; push refused" >&2
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
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.jq pkgs.util-linux];
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
      sessions=$root/sessions
      locks=$PWD/locks
      pins=$PWD/known_hosts.d
      host_pattern=${lib.escapeShellArg "^${upstreamUrl.hostPattern}$"}
      ssh_pattern=${lib.escapeShellArg "^${upstreamUrl.sshPattern}$"}
      scp_pattern=${lib.escapeShellArg "^${upstreamUrl.scpPattern}$"}

      # lib/upstream.nix's grammar; scp-style paths stay home-relative and
      # ssh:// paths absolute, and neither is rewritten, so both name one host.
      relay_host() { # <upstream>
        if [[ $1 =~ $ssh_pattern ]]; then
          printf '%s' "''${BASH_REMATCH[2]}"
        elif [[ $1 != *://* && $1 =~ $scp_pattern ]]; then
          printf '%s' "''${BASH_REMATCH[2]}"
        else
          return 1
        fi
      }

      # The shared credential rule: the key this credential may use for this
      # upstream host, or a refusal that names neither.
      credential_key() { # <credential> <host>
        jq -er --arg credential "$1" --arg host "$2" \
          '${credentialAllowed}' "$config"
      }

      # Forge names become filenames; refuse path separators and dot aliases.
      pin() { # <host>
        mkdir -p "$pins"
        [[ $1 =~ $host_pattern ]] || { echo "git-relay: invalid forge host '$1'" >&2; exit 1; }
        jq -er --arg host "$1" \
          '.forges[$host].hostKeys | select(type == "string" and test("[^[:space:]]"))' \
          "$config" >"$pins/$1" || { echo "git-relay: no forge pins for '$1'" >&2; exit 1; }
      }

      # A served repository — static or session — gets the same forwarding
      # hook, credential, upstream, host pin and receive policy.
      prepare_repo() { # <dir> <credential> <upstream> <host>
        local repo=$1 credential=$2 upstream=$3 host=$4
        # Empty templates refuse host hooks; isolated init uses Git's built-in HEAD default.
        [[ -d $repo ]] || git init --bare --template= --quiet "$repo"
        # Refuse repository-provided hooks in favor of the forwarding hook.
        git -C "$repo" config core.hooksPath ${hooks}
        # The forward refuses client-supplied destinations, keys and trust files.
        git -C "$repo" config relay.credential "$credential"
        git -C "$repo" config relay.host "$host"
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
      }

      # A caller holds flock on the session's lock file for the session's whole
      # life; a lock this process can take itself proves no caller does.
      require_lock() { # <token>
        local lock=$locks/$1
        mkdir -p "$locks"
        exec {lock_probe}<>"$lock"
        if flock -n "$lock_probe"; then
          echo "git-relay: hold flock on $lock first" >&2
          exit 1
        fi
        exec {lock_probe}>&-
      }

      # Reap session directories whose lock this process can take: a live
      # caller holds its lock, so only abandoned sessions go. Lock files
      # without a session directory belong to callers between lock and open,
      # and are never touched.
      session_gc() {
        local session token probe
        mkdir -p "$sessions" "$locks"
        for session in "$sessions"/*.git; do
          [[ -e $session ]] || continue
          token=$(basename -- "$session" .git)
          [[ $token =~ ^[0-9a-f]{32}$ ]] || continue
          exec {probe}<>"$locks/$token"
          if flock -n "$probe"; then
            rm -rf -- "$session"
            rm -f -- "$locks/$token"
          fi
          exec {probe}>&-
        done
      }

      # The daemon takes no arguments; `session` selects session management.
      command=''${1-}
      [[ -z $command || $command == session ]] || {
        echo "git-relay: unknown command $command; the daemon takes no arguments, sessions go through 'git-relay session'" >&2
        exit 1
      }
      case $command in
        session)
          case ''${2-} in
            open)
              shift 2
              token="" credential="" upstream="" alternates=""
              while (($#)); do
                case $1 in
                  --alternates|--credential|--token|--upstream)
                    (($# >= 2)) || { echo "git-relay: session open: $1 needs a value" >&2; exit 1; }
                    # The case patterns are the four literal option names.
                    printf -v "''${1#--}" '%s' "$2"
                    shift 2
                    ;;
                  *)
                    echo "git-relay: session open: unknown option $1" >&2
                    exit 1
                    ;;
                esac
              done
              [[ -n $token && -n $credential && -n $upstream ]] || {
                echo "git-relay: session open needs --token, --credential and --upstream" >&2
                exit 1
              }
              # The token names the lock file, the directory and the URL: 128
              # random bits, as od -An -tx1 -N16 /dev/urandom prints.
              [[ $token =~ ^[0-9a-f]{32}$ ]] || {
                echo "git-relay: a session token is exactly 32 lowercase hex characters" >&2
                exit 1
              }
              host=$(relay_host "$upstream") || {
                echo "git-relay: session upstream must use SSH (ssh:// or [user@]host:path)" >&2
                exit 1
              }
              pin "$host"
              credential_key "$credential" "$host" >/dev/null || {
                echo "git-relay: credential '$credential' absent, keyless, or not allowed for '$host'" >&2
                exit 1
              }
              session_gc
              require_lock "$token"
              prepare_repo "$sessions/$token.git" "$credential" "$upstream" "$host"
              if [[ -n $alternates ]]; then
                [[ $alternates == /* && $alternates != *$'\n'* ]] || {
                  echo "git-relay: --alternates is one absolute object directory path" >&2
                  exit 1
                }
                printf '%s\n' "$alternates" >"$sessions/$token.git/objects/info/alternates"
              fi
              ;;
            close)
              [[ $# == 3 ]] || { echo "git-relay: session close takes one token" >&2; exit 1; }
              token=$3
              [[ $token =~ ^[0-9a-f]{32}$ ]] || {
                echo "git-relay: a session token is exactly 32 lowercase hex characters" >&2
                exit 1
              }
              # The lock holder's exit trap; the lock file goes with the directory.
              require_lock "$token"
              rm -rf -- "$sessions/$token.git"
              rm -f -- "$locks/$token"
              ;;
            gc)
              session_gc
              ;;
            *)
              echo "git-relay: unknown session command ''${2-}; expected open, close or gc" >&2
              exit 1
              ;;
          esac
          ;;
        *) # the daemon; $command is empty here
          listen=$(jq -er .listen "$config")
          port=$(jq -er .port "$config")
          mkdir -p "$root" "$locks"
          hosts=$(jq -r '.forges | keys[]' "$config")
          while IFS= read -r host; do
            pin "$host"
          done <<<"$hosts"
          # Abandoned sessions go at start; a live caller's held lock survives.
          session_gc
          if [[ $(jq -r '.sessions // false' "$config") == true ]]; then
            jq -e '(.repositories // {}) == {}' "$config" >/dev/null || {
              echo "git-relay: a session-only relay serves no repositories" >&2
              exit 1
            }
            # One whitelisted sessions directory serves every descendant, so a
            # new session is served without a daemon restart; without
            # --strict-paths git itself refuses `.` and `..` path aliases, and
            # no static repository is configured or reachable.
            exec git daemon --reuseaddr --listen="$listen" --port="$port" \
              --base-path="$root" --export-all --enable=receive-pack --informative-errors \
              "$sessions"
          fi
          # --strict-paths requires an explicit served directory; empty configs fail.
          names=$(jq -r '.repositories | keys[]' "$config")
          [[ -n $names ]] || { echo "git-relay: no repositories configured" >&2; exit 1; }
          served=()
          while IFS= read -r name; do
            # A direct JSON caller cannot escape the served repository directory.
            [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || {
              echo "git-relay: invalid repository name '$name'" >&2
              exit 1;
            }
            upstream=$(jq -er --arg name "$name" '.repositories[$name].upstream' "$config")
            host=$(relay_host "$upstream") || {
              echo "git-relay: repository '$name': upstream must use SSH (ssh:// or [user@]host:path)" >&2
              exit 1
            }
            # An absent forge must never fall back to the daemon user's known_hosts.
            [[ -s $pins/$host ]] || { echo "git-relay: repository '$name': no forge pins for '$host'" >&2; exit 1; }
            credential=$(jq -er --arg name "$name" '.repositories[$name].credential' "$config")
            credential_key "$credential" "$host" >/dev/null || {
              echo "git-relay: repository '$name': credential '$credential' absent, keyless, or not allowed for '$host'" >&2
              exit 1
            }
            prepare_repo "$root/$name.git" "$credential" "$upstream" "$host"
            served+=("$root/$name.git")
          done <<<"$names"

          # Explicit strict paths refuse unconfigured and stale repos; export-all
          # serves these paths without trusting a git-daemon-export-ok marker.
          exec git daemon --reuseaddr --listen="$listen" --port="$port" \
            --base-path="$root" --strict-paths --export-all --enable=receive-pack --informative-errors \
            "''${served[@]}"
          ;;
      esac
    '';
  }
