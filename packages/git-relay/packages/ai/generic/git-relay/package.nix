# cspell:ignore refspecs
# git-relay: the AI git relay daemon. Agents push to
# git://<listen>:<port>/<repository>.git; the pre-receive hook forwards the
# whole push to the repository's upstream with a key the agent never holds and
# refuses the push when the forward fails, so the relay never gets ahead of
# its upstream. Configured by the JSON file named in GIT_RELAY_CONFIG
# (packages/git-relay/docs/git-relay.md).
{
  pkgs,
  strictShellApplication,
  ...
}: let
  inherit (pkgs) lib;
  strict = strictShellApplication pkgs;

  # Runs inside the daemon, as its user, never as the pushing agent. Force
  # pushes and deletes pass through: agents rewrite their stacks.
  preReceive = strict {
    name = "pre-receive";
    runtimeInputs = [pkgs.git];
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
      # A repository the launcher did not configure has no upstream to forward to.
      upstream=$(git config --get relay.upstream) || {
        echo "git-relay: no relay.upstream configured; push refused" >&2
        exit 1
      }
      # GIT_SSH_COMMAND comes from the launcher through the daemon's environment.
      if ! git push --atomic "$upstream" "''${refspecs[@]}"; then
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
      config=''${GIT_RELAY_CONFIG:?GIT_RELAY_CONFIG must name the JSON config file}
      root=$PWD/repositories
      # git daemon --strict-paths refuses to start without a directory to
      # serve, and names no cause.
      names=$(jq -r '.repositories | keys[]' "$config")
      [[ -n $names ]] || { echo "git-relay: no repositories configured" >&2; exit 1; }
      mkdir -p "$root"
      served=()
      while IFS= read -r name; do
        repo=$root/$name.git
        [[ -d $repo ]] || git init --bare --quiet "$repo"
        git -C "$repo" config core.hooksPath ${hooks}
        upstream=$(jq -er --arg name "$name" '.repositories[$name].upstream' "$config")
        git -C "$repo" config relay.upstream "$upstream"
        git -C "$repo" config receive.advertisePushOptions false
        git -C "$repo" config receive.fsckObjects true
        served+=("$repo")
      done <<<"$names"

      # The forward's identity. An inherited GIT_SSH_COMMAND would carry
      # another one into the hook. ssh wants the known hosts as a file, so
      # it is written here. The key is a path the service launcher filled in.
      unset GIT_SSH_COMMAND
      key=$(jq -r '.sshKeyFile // empty' "$config")
      if [[ -n $key ]]; then
        options=(-F none -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes)
        known_hosts=$(jq -r '.knownHosts // empty' "$config")
        if [[ -n $known_hosts ]]; then
          printf '%s\n' "$known_hosts" >"$PWD/known_hosts"
          options+=(-o "UserKnownHostsFile=$PWD/known_hosts")
        fi
        GIT_SSH_COMMAND="${lib.getExe' pkgs.openssh "ssh"} $(printf '%q ' "''${options[@]}")"
        export GIT_SSH_COMMAND
      fi

      # --export-all and --strict-paths: only the directories listed are served,
      # without a git-daemon-export-ok file in each.
      listen=$(jq -er .listen "$config")
      port=$(jq -er .port "$config")
      exec git daemon --reuseaddr --listen="$listen" --port="$port" \
        --base-path="$root" --strict-paths --export-all --enable=receive-pack --informative-errors \
        "''${served[@]}"
    '';
  }
