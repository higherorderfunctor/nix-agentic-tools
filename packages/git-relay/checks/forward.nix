# The relay's contract, against the packaged daemon and a local upstream: a
# push is forwarded whole, and refused when the forward fails, with the relay
# ref not advancing. Force pushes and deletes pass through, only configured
# repositories are served, and the forward gets the launcher's ssh identity.
# Linux only: a Darwin build sandbox has no loopback networking by default.
{
  lib,
  pkgs,
  self,
  ...
}: let
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
  strict = import ../../../lib/strict-shell-application.nix pkgs;
  relay = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.git-relay;
  port = 28450;
  # The upstream's update hook records the ssh identity the forward carried,
  # and refuses the ref `reject`: git fails the rest of an atomic push with it.
  upstreamHook = strict {
    name = "git-relay-upstream-update";
    text = ''
      printf '%s' "''${GIT_SSH_COMMAND-unset}" >"$GIT_DIR/forward-ssh"
      [[ $1 != refs/heads/reject ]]
    '';
  };
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    git-relay-forward = mkLintedCheck "git-relay-forward" {
      runtimeInputs = [pkgs.coreutils pkgs.git pkgs.gnugrep];
      text = ''
        # The caller's git configuration must not reach the relay or its upstream.
        export GIT_CONFIG_GLOBAL=$PWD/gitconfig GIT_CONFIG_NOSYSTEM=1
        git config --global init.defaultBranch main
        git config --global user.name relay-check
        git config --global user.email relay-check@example.invalid
        base=$PWD
        url=git://127.0.0.1:${toString port}

        # Two configured repositories, one whose upstream does not exist.
        git init --bare --quiet upstream/ok.git
        cp ${lib.getExe upstreamHook} upstream/ok.git/hooks/update
        printf 'not a real key' >key
        printf 'github.com ssh-ed25519 AAAA\n' >hosts
        cat >relay.json <<JSON
        {
          "listen": "127.0.0.1",
          "port": ${toString port},
          "repositories": {
            "down": {"upstream": "$base/upstream/missing.git"},
            "ok": {"upstream": "$base/upstream/ok.git"}
          },
          "sshKeyFile": "$base/key",
          "knownHosts": "$(<hosts)"
        }
        JSON
        # A repository left from an earlier configuration is not served.
        mkdir state
        git init --bare --quiet state/repositories/stale.git

        pid=
        # TERM, not KILL: `git daemon` runs git-daemon as a child, which only git's signal handler stops.
        trap '[[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || :' EXIT
        start() {
          (cd state && GIT_RELAY_CONFIG=$base/$1 exec ${lib.getExe relay}) >relay.log 2>&1 &
          pid=$!
          for _ in {1..100}; do
            if git ls-remote "$url/ok.git" >/dev/null 2>&1; then return 0; fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
          done
          cat relay.log >&2
          echo "relay did not start" >&2
          return 1
        }
        stop() {
          kill -TERM "$pid"
          wait "$pid" || :
          pid=
        }
        # A negated command is exempt from errexit, so absence is tested here.
        absent() {
          if "$@" >/dev/null 2>&1; then
            echo "FAIL: succeeded: $*" >&2
            return 1
          fi
        }
        refused() {
          absent git -C work push "$@"
          git -C work push "$@" >push.log 2>&1 || :
          grep -F 'push refused' push.log
        }
        tip() { git -C "$1" rev-parse --verify "$2"; }

        start relay.json

        git init --quiet work
        git -C work commit --quiet --allow-empty -m first
        git -C work remote add relay "$url/ok.git"
        git -C work push --quiet relay main
        [[ $(tip upstream/ok.git refs/heads/main) == "$(tip work HEAD)" ]]
        [[ $(tip state/repositories/ok.git refs/heads/main) == "$(tip work HEAD)" ]]
        # Fetching from the relay returns what was pushed.
        git clone --quiet "$url/ok.git" clone
        [[ $(tip clone HEAD) == "$(tip work HEAD)" ]]

        # The forward carried the launcher's identity, as a path to the key.
        ssh=$(<upstream/ok.git/forward-ssh)
        for expected in "-i $base/key " IdentitiesOnly=yes StrictHostKeyChecking=yes "UserKnownHostsFile=$base/state/known_hosts"; do
          grep -qF -- "$expected" <<<"$ssh"
        done
        absent grep -qF 'not a real key' <<<"$ssh"
        [[ $(<state/known_hosts) == "$(<hosts)" ]]

        # A force push and a delete pass through.
        git -C work commit --quiet --amend --allow-empty -m rewritten
        git -C work push --quiet --force relay main
        [[ $(tip upstream/ok.git refs/heads/main) == "$(tip work HEAD)" ]]
        git -C work push --quiet relay main:topic
        git -C work push --quiet relay :topic
        absent git -C upstream/ok.git rev-parse --verify --quiet refs/heads/topic
        absent git -C state/repositories/ok.git rev-parse --verify --quiet refs/heads/topic

        # An atomic push the upstream refuses in part changes nothing, here or there.
        before=$(tip upstream/ok.git refs/heads/main)
        git -C work commit --quiet --allow-empty -m second
        refused relay HEAD:main HEAD:reject
        [[ $(tip upstream/ok.git refs/heads/main) == "$before" ]]
        [[ $(tip state/repositories/ok.git refs/heads/main) == "$before" ]]

        # An unreachable upstream refuses the push and the relay stays empty.
        git -C work remote add down "$url/down.git"
        refused down HEAD:main
        absent git -C state/repositories/down.git rev-parse --verify --quiet refs/heads/main

        # Repositories not configured, and left-over ones, are not served.
        absent git ls-remote "$url/stale.git"
        absent git ls-remote "$url/unknown.git"

        # With no key the forward carries no identity, even an inherited one.
        stop
        sed -i 's|"sshKeyFile": "[^"]*"|"sshKeyFile": null|' relay.json
        GIT_SSH_COMMAND=inherited start relay.json
        git -C work push --quiet relay HEAD:main
        [[ $(<upstream/ok.git/forward-ssh) == unset ]]
        stop
      '';
    };
  };
}
