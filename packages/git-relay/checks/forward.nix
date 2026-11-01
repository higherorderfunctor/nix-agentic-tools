# cspell:ignore AAAAFIRST AAAASECOND identityfile stricthostkeychecking
# The packaged daemon forwards whole pushes with each repository's key and
# pinned host. Failed forwards never advance relay refs; inherited Git policy
# cannot redirect forwarding or prevent an agent's force push or deletion.
# Linux only: a Darwin build sandbox has no loopback networking by default.
{
  lib,
  pkgs,
  ...
}: let
  inherit (import ./transport.nix {inherit pkgs;}) fakeSsh relay upstreamHook;
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
  port = 28450;
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    git-relay-forward = mkLintedCheck "git-relay-forward" {
      runtimeInputs = [pkgs.coreutils pkgs.git pkgs.gnugrep pkgs.jq pkgs.openssh];
      text = ''
        base="$PWD/relay none check"
        mkdir "$base"
        cd "$base"
        state="$base/relay state"
        url=git://127.0.0.1:${toString port}
        export GIT_CONFIG_GLOBAL="$base/client.gitconfig" GIT_CONFIG_NOSYSTEM=1
        git config --global init.defaultBranch main
        git config --global user.name relay-check
        git config --global user.email relay-check@example.invalid

        # The client's settings remain usable while the daemon inherits hostile
        # global, system, command-scope, and template configuration.
        mkdir template
        touch template/injected
        hostile="$base/hostile.gitconfig"
        git config --file "$hostile" init.defaultBranch hostile-branch
        git config --file "$hostile" init.templateDir "$base/template"
        git config --file "$hostile" receive.denyDeletes true
        git config --file "$hostile" --add url."file://$base/redirected/".insteadOf git@one.example.invalid:
        git config --file "$hostile" --add url."file://$base/redirected/".insteadOf ssh://git@two.example.invalid:2222/

        git init --bare --quiet upstream/ok.git
        git init --bare --quiet upstream/second.git
        for name in ok second; do
          cp ${lib.getExe upstreamHook} "upstream/$name.git/hooks/update"
        done
        printf 'first private fixture' >"first key"
        printf 'second private fixture' >"second key"
        first_pin='one.example.invalid ssh-ed25519 AAAAFIRST'
        second_pin='[two.example.invalid]:2222 ssh-ed25519 AAAASECOND'
        jq -n --arg base "$base" --arg first "$first_pin" --arg second "$second_pin" '
          {
            credentials: {
              first: {forges: ["one.example.invalid"], sshKeyFile: ($base + "/first key")},
              second: {forges: ["two.example.invalid"], sshKeyFile: ($base + "/second key")}
            },
            forges: {
              "one.example.invalid": {hostKeys: $first},
              "two.example.invalid": {hostKeys: $second}
            },
            listen: "127.0.0.1",
            port: ${toString port},
            repositories: {
              down: {credential: "first", upstream: ("git@one.example.invalid:" + $base + "/upstream/missing.git")},
              ok: {credential: "first", upstream: ("git@one.example.invalid:" + $base + "/upstream/ok.git")},
              second: {credential: "second", upstream: ("ssh://git@two.example.invalid:2222" + $base + "/upstream/second.git")}
            }
          }' >relay.json
        # A repository left by an earlier configuration must not be served.
        mkdir "$state"
        git init --bare --quiet "$state/repositories/stale.git"

        pid=
        # TERM lets git daemon stop its git-daemon child as well.
        trap '[[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || :' EXIT
        start() {
          (
            cd "$state"
            export GIT_CONFIG="$hostile" GIT_CONFIG_GLOBAL="$hostile" GIT_CONFIG_SYSTEM="$hostile"
            export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=receive.denyDeletes GIT_CONFIG_VALUE_0=true
            export GIT_CONFIG_KEY_1=url.file:///missing/.insteadOf GIT_CONFIG_VALUE_1=git@one.example.invalid:
            export GIT_CONFIG_PARAMETERS="'receive.denyDeletes=true'"
            export GIT_DIR="$base/wrong-repository" GIT_WORK_TREE="$base/wrong-worktree"
            export GIT_COMMON_DIR="$base/wrong-common" GIT_OBJECT_DIRECTORY="$base/wrong-objects"
            export GIT_SSH_COMMAND=false GIT_SSH=false GIT_SSH_VARIANT=plink
            export GIT_TEMPLATE_DIR="$base/template"
            GIT_RELAY_CONFIG="$base/$1" exec ${lib.getExe relay}
          ) >relay.log 2>&1 &
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
        # Negation skips errexit; this helper turns unexpected success into failure.
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
        identity() {
          local repo=$1 key=$2 host=$3 other=$4 ssh
          ssh=$(<"upstream/$repo.git/forward-ssh")
          # Parse the shell quoting Git consumes: spaces in key/state paths
          # must survive as one SSH argument, rather than merely appear in text.
          eval "set -- $ssh"
          [[ $1 == ${lib.getExe fakeSsh} ]]
          shift
          local -a args=("$@")
          printf '%s\n' "''${args[@]}" >ssh-args
          grep -qxF -- "$base/$key key" ssh-args
          grep -qxF -- "UserKnownHostsFile=\"$state/known_hosts.d/$host\"" ssh-args
          for expected in IdentitiesOnly=yes IdentityAgent=none StrictHostKeyChecking=yes; do
            grep -qxF -- "$expected" ssh-args
          done
          absent grep -qF -- "$base/$other key" ssh-args
          absent grep -qF 'private fixture' ssh-args
        }

        start relay.json
        for name in down ok second; do
          [[ ! -e $state/repositories/$name.git/injected ]]
          [[ $(git -C "$state/repositories/$name.git" symbolic-ref --short HEAD) != hostile-branch ]]
        done
        [[ $(<"$state/known_hosts.d/one.example.invalid") == "$first_pin" ]]
        [[ $(<"$state/known_hosts.d/two.example.invalid") == "$second_pin" ]]

        git init --quiet work
        git -C work commit --quiet --allow-empty -m first
        git -C work remote add relay "$url/ok.git"
        git -C work remote add second "$url/second.git"
        for name in ok second; do
          git -C work push --quiet "$url/$name.git" main
          [[ $(tip "upstream/$name.git" refs/heads/main) == "$(tip work HEAD)" ]]
          [[ $(tip "$state/repositories/$name.git" refs/heads/main) == "$(tip work HEAD)" ]]
        done
        identity ok first one.example.invalid second
        identity second second two.example.invalid first
        git clone --quiet -b main "$url/ok.git" clone
        [[ $(tip clone HEAD) == "$(tip work HEAD)" ]]

        # Real OpenSSH accepts the escaped key/pin options observed above.
        eval "set -- $(<upstream/ok.git/forward-ssh)"
        shift
        ssh -G "$@" one.example.invalid >ssh-config
        grep -qxF 'stricthostkeychecking true' ssh-config
        # An unreadable -i must not re-enable the daemon user's default keys.
        args=("$@")
        for index in "''${!args[@]}"; do
          if [[ ''${args[index]} == -i ]]; then args[index+1]="$base/missing key"; fi
        done
        ssh -G "''${args[@]}" one.example.invalid >missing-key-config
        [[ $(grep '^identityfile ' missing-key-config) == 'identityfile none' ]]

        git -C work commit --quiet --amend --allow-empty -m rewritten
        git -C work push --quiet --force relay main
        [[ $(tip upstream/ok.git refs/heads/main) == "$(tip work HEAD)" ]]
        git -C work push --quiet relay main:topic
        git -C work push --quiet relay :topic
        absent git -C upstream/ok.git rev-parse --verify --quiet refs/heads/topic
        absent git -C "$state/repositories/ok.git" rev-parse --verify --quiet refs/heads/topic

        # Atomic rejection leaves all refs unchanged at both ends.
        before=$(tip upstream/ok.git refs/heads/main)
        git -C work commit --quiet --allow-empty -m second
        refused relay HEAD:main HEAD:reject
        [[ $(tip upstream/ok.git refs/heads/main) == "$before" ]]
        [[ $(tip "$state/repositories/ok.git" refs/heads/main) == "$before" ]]
        absent git -C upstream/ok.git rev-parse --verify --quiet refs/heads/reject
        absent git -C "$state/repositories/ok.git" rev-parse --verify --quiet refs/heads/reject

        git -C work remote add down "$url/down.git"
        refused down HEAD:main
        absent git -C "$state/repositories/down.git" rev-parse --verify --quiet refs/heads/main
        absent git ls-remote "$url/stale.git"
        absent git ls-remote "$url/unknown.git"

        # Deleting the relay's own HEAD branch must pass receive policy too.
        head=$(git -C "$state/repositories/ok.git" symbolic-ref --short HEAD)
        git -C work push --quiet relay "HEAD:$head"
        git -C work push --quiet relay ":$head"
        absent git -C upstream/ok.git rev-parse --verify --quiet "refs/heads/$head"
        absent git -C "$state/repositories/ok.git" rev-parse --verify --quiet "refs/heads/$head"

        # Config edits take effect inside each push, without restarting the daemon.
        before=$(tip "$state/repositories/second.git" refs/heads/main)
        jq 'del(.credentials.second)' relay.json >next.json
        mv next.json relay.json
        refused --force second HEAD:main
        grep -F "credential 'second' absent, keyless, or not allowed for 'two.example.invalid'" push.log
        [[ $(tip upstream/second.git refs/heads/main) == "$before" ]]
        [[ $(tip "$state/repositories/second.git" refs/heads/main) == "$before" ]]
        stop

        # A direct JSON caller cannot bypass the module's SSH-only upstream rule.
        jq --arg upstream "$base/upstream/ok.git" '.repositories.ok.upstream = $upstream' relay.json >local.json
        if (cd "$state"; GIT_RELAY_CONFIG="$base/local.json" exec ${lib.getExe relay}) >local.log 2>&1; then
          echo 'FAIL: launcher accepted a local upstream' >&2
          exit 1
        fi
        grep -F 'upstream must use SSH' local.log
      '';
    };
  };
}
