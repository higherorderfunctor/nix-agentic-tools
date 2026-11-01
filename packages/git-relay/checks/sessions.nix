# cspell:ignore AAAASSESSION deadbeefdeadbeefdeadbeefdeadbeef TOOSHORT urandom
# Session repositories: opened under a caller-held flock, served the moment
# they appear by a session-only daemon, forwarded with their own credential,
# reaped only when unlocked, and refused once the credential loses the
# upstream host. Static repositories stay unreachable. Upstream URLs pass
# through verbatim: a scp-style target without .git neither gains nor needs
# the suffix. Linux only: a Darwin build sandbox has no loopback networking.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ./transport.nix {inherit pkgs;}) relay upstreamHook;
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
  port = 28451;
  # Fixed tokens stand in for od -An -tx1 -N16 /dev/urandom output.
  held = "0f1e2d3c4b5a69788796a5b4c3d2e1f0";
  fresh = "1a2b3c4d5e6f708192a3b4c5d6e7f809";
  abandoned = "deadbeefdeadbeefdeadbeefdeadbeef";
  unknown = "99999999999999999999999999999999";
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    git-relay-sessions = mkLintedCheck "git-relay-sessions" {
      runtimeInputs = [pkgs.coreutils pkgs.git pkgs.gnugrep pkgs.jq pkgs.util-linux];
      text = ''
        base="$PWD/git-relay sessions check"
        mkdir "$base"
        cd "$base"
        state="$base/relay state"
        url=git://127.0.0.1:${toString port}
        export GIT_CONFIG_GLOBAL="$base/client.gitconfig" GIT_CONFIG_NOSYSTEM=1
        git config --global init.defaultBranch main
        git config --global user.name relay-check
        git config --global user.email relay-check@example.invalid

        printf 'session private fixture' >"session key"
        pin='sessions.example.invalid ssh-ed25519 AAAASSESSION'
        # The scp-style upstream carries no .git; the ssh:// one already ends in it.
        scp_upstream="git@sessions.example.invalid:$base/upstream/scp-target"
        ssh_upstream="ssh://git@sessions.example.invalid$base/upstream/ssh-target.git"
        jq -n --arg base "$base" --arg key "session key" --arg pin "$pin" '
          {
            credentials: {work: {forges: ["sessions.example.invalid"], sshKeyFile: ($base + "/session key")}},
            forges: {"sessions.example.invalid": {hostKeys: $pin}},
            listen: "127.0.0.1",
            port: ${toString port},
            sessions: true
          }' >relay.json
        mkdir "$state"
        mkdir upstream
        git init --bare --quiet upstream/scp-target
        git init --bare --quiet upstream/ssh-target.git
        for name in scp-target ssh-target.git; do
          cp ${lib.getExe upstreamHook} "upstream/$name/hooks/update"
        done
        # A static repository left by an earlier configuration must not be served.
        git init --bare --quiet "$state/repositories/stale.git"

        # The launcher's flow: hold flock on the session's lock file, run the
        # subcommand under it, release. The held session keeps its lock in this
        # shell for the whole check; this subshell takes a lock when it is
        # free and leaves one alone that a live caller already holds.
        locked() { # <token> <session arguments...>
          local token=$1
          shift
          (
            cd "$state"
            exec {lock_fd}<>"locks/$token"
            flock -n "$lock_fd" || :
            GIT_RELAY_CONFIG="$base/relay.json" exec ${lib.getExe relay} session "$@"
          )
        }
        absent() {
          if "$@" >/dev/null 2>&1; then
            echo "FAIL: succeeded: $*" >&2
            return 1
          fi
        }
        tip() { git -C "$1" rev-parse --verify "$2"; }

        mkdir -p "$state/locks"
        exec {held_lock}<>"$state/locks/${held}"
        flock -n "$held_lock"
        locked "${held}" open --token "${held}" --credential work --upstream "$ssh_upstream"
        locked "${abandoned}" open --token "${abandoned}" --credential work --upstream "$ssh_upstream"
        [[ -d $state/repositories/sessions/${held}.git ]]
        [[ -d $state/repositories/sessions/${abandoned}.git ]]

        pid=
        # TERM lets git daemon stop its git-daemon child as well.
        trap '[[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || :' EXIT
        (
          cd "$state"
          GIT_RELAY_CONFIG="$base/relay.json" exec ${lib.getExe relay}
        ) >relay.log 2>&1 &
        pid=$!
        for _ in {1..100}; do
          if git ls-remote "$url/sessions/${held}.git" >/dev/null 2>&1; then break; fi
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.1
        done
        git ls-remote "$url/sessions/${held}.git" >/dev/null || {
          cat relay.log >&2
          echo "relay did not start" >&2
          exit 1
        }
        # The start gc reaped the abandoned session; the held lock kept its own.
        [[ ! -e $state/repositories/sessions/${abandoned}.git ]]
        [[ ! -e $state/locks/${abandoned} ]]

        # A session opened after the daemon started is served without a restart.
        locked "${fresh}" open --token "${fresh}" --credential work \
          --upstream "$scp_upstream" --alternates "$base/upstream/ssh-target.git/objects"
        [[ $(<"$state/repositories/sessions/${fresh}.git/objects/info/alternates") \
          == "$base/upstream/ssh-target.git/objects" ]]
        git ls-remote "$url/sessions/${fresh}.git" >/dev/null

        git init --quiet work
        git -C work commit --quiet --allow-empty -m first
        git -C work remote add fresh "$url/sessions/${fresh}.git"
        git -C work remote add held "$url/sessions/${held}.git"
        git -C work push --quiet fresh main
        [[ $(tip upstream/scp-target refs/heads/main) == $(git -C work rev-parse HEAD) ]]
        # The scp-style upstream was forwarded verbatim; no .git was appended.
        [[ ! -e upstream/scp-target.git ]]
        git -C work push --quiet held main
        [[ $(tip upstream/ssh-target.git refs/heads/main) == $(git -C work rev-parse HEAD) ]]

        # The forward used the session's credential key and the forge's pin file.
        eval "set -- $(<upstream/scp-target/forward-ssh)"
        shift
        printf '%s\n' "$@" >ssh-args
        grep -qxF -- "$base/session key" ssh-args
        grep -qxF -- "UserKnownHostsFile=\"$state/known_hosts.d/sessions.example.invalid\"" ssh-args
        grep -qxF -- IdentitiesOnly=yes ssh-args

        # Wrong tokens serve nothing; malformed ones never open.
        absent git ls-remote "$url/sessions/${unknown}.git"
        for token in TOOSHORT ${held}% 0F1E2D3C4B5A69788796A5B4C3D2E1F0; do
          if locked "$token" open --token "$token" --credential work \
            --upstream "$scp_upstream" >open.log 2>&1; then
            echo "FAIL: open accepted token $token" >&2
            exit 1
          fi
        done
        grep -F 'a session token is exactly 32 lowercase hex characters' open.log
        # A non-SSH upstream and an unpinned host never open a session.
        if locked "${unknown}" open --token "${unknown}" --credential work \
          --upstream "https://github.com/owner/repo.git" >open.log 2>&1; then
          echo "FAIL: open accepted an https upstream" >&2
          exit 1
        fi
        grep -F 'upstream must use SSH' open.log
        if locked "${unknown}" open --token "${unknown}" --credential work \
          --upstream "git@unpinned.example.invalid:$base/upstream/scp-target" >open.log 2>&1; then
          echo "FAIL: open accepted an unpinned host" >&2
          exit 1
        fi
        grep -F "no forge pins for 'unpinned.example.invalid'" open.log

        # open refuses a lock the caller does not hold, and creates nothing.
        if (cd "$state"; GIT_RELAY_CONFIG="$base/relay.json" exec ${lib.getExe relay} session open \
          --token "${unknown}" --credential work --upstream "$ssh_upstream") >open.log 2>&1; then
          echo "FAIL: open without the lock succeeded" >&2
          exit 1
        fi
        grep -F "hold flock on $state/locks/${unknown} first" open.log
        [[ ! -e $state/repositories/sessions/${unknown}.git ]]

        # The control above serves the held session; these paths are refused by
        # git daemon's own `.`/`..` alias checks and by the sessions-only
        # whitelist, not by the token.
        absent git ls-remote "$url/sessions/../sessions/${held}.git"
        absent git ls-remote "$url/../stale.git"
        absent git ls-remote "$url/stale.git"

        # Removing the credential's permission for the upstream host revokes
        # the session: the next push is refused and no new session opens.
        before=$(tip upstream/ssh-target.git refs/heads/main)
        jq '.credentials.work.forges = []' relay.json >revoked.json
        mv revoked.json relay.json
        git -C work push held main:revoked >push.log 2>&1 || :
        grep -F "not allowed for 'sessions.example.invalid'" push.log
        [[ $(tip upstream/ssh-target.git refs/heads/main) == "$before" ]]
        absent git -C "$state/repositories/sessions/${held}.git" rev-parse --verify --quiet refs/heads/revoked
        if locked "${unknown}" open --token "${unknown}" --credential work \
          --upstream "$ssh_upstream" >open.log 2>&1; then
          echo "FAIL: open under a revoked routing succeeded" >&2
          exit 1
        fi
        grep -F "not allowed for 'sessions.example.invalid'" open.log

        # gc reaps the unlocked fresh session and never touches the held one.
        (cd "$state"; GIT_RELAY_CONFIG="$base/relay.json" exec ${lib.getExe relay} session gc)
        [[ ! -e $state/repositories/sessions/${fresh}.git ]]
        [[ -d $state/repositories/sessions/${held}.git ]]
        git ls-remote "$url/sessions/${held}.git" >/dev/null

        # close removes the session directory and its lock file under the lock.
        locked "${held}" close "${held}"
        [[ ! -e $state/repositories/sessions/${held}.git ]]
        [[ ! -e $state/locks/${held} ]]
        absent git ls-remote "$url/sessions/${held}.git"
      '';
    };
  };
}
