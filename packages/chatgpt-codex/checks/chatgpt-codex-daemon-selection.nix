# Runtime contract: the Home Manager daemon selection, run against the real
# package and the real daemon in a throwaway Codex home.
#
# mkCodex.nix points `$CODEX_HOME/packages/app-server-daemon/current` straight
# at the store package (daemonSelect.nix). That layout is outside upstream's
# documented `releases/<version>-<target>`, so this check is the canary for a
# Codex release that stops honoring it: a bump that breaks it fails here, in
# the update PR, rather than in a user's session. It drives the activation
# text Home Manager renders, so wiring and script are exercised together. It
# calls the selector directly only where it needs a package root no module
# evaluation can name: the simulated bump, and the stub roots whose stop fails
# or hangs, which drive the selector's warn-and-continue paths.
#
# Linux only: the daemon's pid backend and /proc are what it inspects.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  codex = harness.aiStubs.chatgpt-codex;
  root = "${codex}/${codex.passthru.codexPackage.root}";
  select = import ../lib/daemonSelect.nix pkgs;
  # The same selector with both waits cut to seconds, so the check can
  # outlast them without taking minutes.
  quick = select.override {
    selectLockSeconds = 1;
    stopTimeoutSeconds = 2;
  };
  # Package roots whose `codex` only stands in for `app-server daemon stop`:
  # it fails, hangs, or succeeds and leaves a marker in the Codex home.
  stubRoot = name: body:
    pkgs.writeTextFile {
      name = "codex-stub-${name}";
      destination = "/bin/codex";
      executable = true;
      text = ''
        #!${pkgs.runtimeShell}
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${body}
      '';
    };
  stubs = {
    failing = stubRoot "failing" "exit 3";
    hanging = stubRoot "hanging" "exec ${pkgs.coreutils}/bin/sleep 60";
    stopping = stubRoot "stopping" '': > "$CODEX_HOME/stopped"'';
  };
  # The selection and the updater leaf, in the order Home Manager runs them.
  activation = pinDaemonToPackage: let
    entries =
      (harness.evalHm {
        ai.codex = {
          enable = true;
          inherit pinDaemonToPackage;
        };
      })
      .config
      .home
      .activation;
  in
    entries.codexDaemonSettingsReconcile.text + entries.codexDaemonSelect.text;
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    chatgpt-codex-daemon-selection =
      pkgs.runCommand "chatgpt-codex-daemon-selection" {
        nativeBuildInputs = [pkgs.coreutils pkgs.flock pkgs.jq pkgs.procps];
      } ''
        ${harness.hmRunShim}
        fail() {
          echo "FAIL: $*" >&2
          exit 1
        }
        pin() {
        ${activation true}
        }
        unpin() {
        ${activation false}
        }

        # A short HOME keeps the daemon's control socket under the Unix
        # path-length limit.
        export HOME="$TMPDIR/h"
        export XDG_STATE_HOME="$TMPDIR/state"
        export CODEX_HOME="$HOME/.codex"
        selection="$CODEX_HOME/packages/app-server-daemon"
        settings="$CODEX_HOME/app-server-daemon/settings.json"
        mkdir -p "$selection"
        # Retracting the last leaf removes the file the writer created.
        updater() {
          if [ -e "$settings" ]; then
            jq -c '.updater // {}' "$settings"
          else
            echo '{}'
          fi
        }

        # Every start runs the selected package in place: no copy into
        # releases/, and no updater. Upstream re-arms its updater after every
        # start, so each start is checked, not just the first.
        start() {
          timeout 120 "$1/bin/codex" app-server daemon start < /dev/null > start.json \
            || fail "daemon start from $1 failed"
          pid="$(jq -er .pid start.json)" || fail "daemon start reported no pid: $(cat start.json)"
          exe="$(readlink "/proc/$pid/exe")"
          [ "$exe" = "$1/bin/codex" ] || fail "daemon runs $exe, not $1/bin/codex"
          sleep 2
          [ ! -e "$selection/releases" ] || fail "the daemon from $1 copied the package into releases/"
          [ ! -e "$CODEX_HOME/app-server-daemon/daemon-updater.pid" ] \
            || fail "the daemon from $1 started its updater"
          if pgrep -f pid-update-loop > /dev/null; then
            fail "a pid-update-loop process is running beside the daemon from $1"
          fi
        }
        # Gone or a zombie: an orphaned daemon is reaped by this shell, the
        # sandbox's pid 1, only between commands.
        stopped() {
          for _ in $(seq 50); do
            state="$(cut -d ' ' -f 3 "/proc/$1/stat" 2> /dev/null)" || return 0
            [ "$state" != Z ] || return 0
            sleep 0.2
          done
          fail "daemon $1 is still running: $2"
        }

        # An earlier upstream-managed selection leaves the updater's marker.
        echo 0.157.1-x86_64-unknown-linux-musl > "$selection/auto-update-version"

        pin
        [ "$(readlink "$selection/current")" = ${root} ] \
          || fail "pin selected $(readlink "$selection/current")"
        [ ! -e "$selection/auto-update-version" ] || fail "pin left the updater marker"

        [ "$(updater)" = '{"autoUpdateEnabled":false}' ] || fail "pin wrote updater $(updater)"

        start ${root}
        first="$pid"

        # An unchanged package is a no-op: the running daemon is kept. The
        # selection waits for upstream's operation lock: a holder that marks
        # its release must have marked it by the time the selection returns.
        flock "$CODEX_HOME/app-server-daemon/daemon.lock" \
          sh -c 'touch "$1/held"; sleep 2; touch "$1/released"' _ "$TMPDIR" &
        for _ in $(seq 50); do
          [ ! -e "$TMPDIR/held" ] || break
          sleep 0.1
        done
        [ -e "$TMPDIR/held" ] || fail "the lock holder never took the operation lock"
        pin
        [ -e "$TMPDIR/released" ] || fail "the selection ran while another command held the operation lock"
        wait
        kill -0 "$first" 2> /dev/null || fail "re-pinning the same package stopped the daemon"

        # A bump: a different root is selected and the old daemon stopped,
        # not restarted; the next start runs the new package.
        cp -r ${root} "$TMPDIR/bumped"
        ${lib.getExe select} "$CODEX_HOME" "$TMPDIR/bumped"
        [ "$(readlink "$selection/current")" = "$TMPDIR/bumped" ] \
          || fail "the bump selected $(readlink "$selection/current")"
        stopped "$first" "a changed package must stop the old daemon"
        start "$TMPDIR/bumped"
        bumped="$pid"

        # Back to the store, then unpinned: the store selection is released
        # and its daemon stopped, so nothing points at a path GC may remove.
        pin
        stopped "$bumped" "re-pinning the store package must stop the bumped daemon"
        start ${root}
        unpin
        [ ! -e "$selection/current" ] && [ ! -L "$selection/current" ] \
          || fail "unpinning left current -> $(readlink "$selection/current")"
        [ "$(updater)" = '{}' ] || fail "unpinning left updater $(updater)"
        stopped "$pid" "unpinning must stop the store daemon"

        # Unpinned or disabled, the selector releases only what it writes. A
        # store link of any other shape, such as a home.file-managed one, stays.
        foreign=${builtins.storeDir}/00000000000000000000000000000000-home-manager-files/.codex/packages/app-server-daemon/current
        ln -s "$foreign" "$selection/current"
        unpin
        [ "$(readlink "$selection/current")" = "$foreign" ] \
          || fail "unpinning removed a current it did not write"

        # A stop that fails or hangs only warns: activation still succeeds and
        # keeps the new selection, and the warning names the command to run.
        lock="$CODEX_HOME/app-server-daemon/daemon.lock"
        selects() {
          ${lib.getExe quick} "$CODEX_HOME" "$1" 2> "$TMPDIR/err" \
            || fail "the selector failed activation: $(cat "$TMPDIR/err")"
          cat "$TMPDIR/err" >&2
          [ "$(readlink "$selection/current")" = "$1" ] || fail "$2 lost the selection"
        }
        warned() {
          grep -qF "warning: $1" "$TMPDIR/err" || fail "no warning \"$1\" on stderr: $(cat "$TMPDIR/err")"
        }

        selects ${stubs.failing} "a failed stop"
        warned "stopping the Codex app-server daemon failed with exit status 3; it may still be running $foreign until it exits. Stop it with: CODEX_HOME=$CODEX_HOME ${stubs.failing}/bin/codex app-server daemon stop"

        began="$(date +%s)"
        selects ${stubs.hanging} "a hung stop"
        [ $(($(date +%s) - began)) -lt 20 ] || fail "the selector waited out a hung stop"
        warned "stopping the Codex app-server daemon did not finish within 2s"

        # Another lifecycle command holding the lock past the wait: the
        # selection is made without it, with a warning, and the stop still runs.
        flock "$lock" sleep 60 &
        holder=$!
        for _ in $(seq 50); do
          flock -n "$lock" true || break
          sleep 0.1
        done
        if flock -n "$lock" true; then
          fail "the lock holder never took the operation lock"
        fi
        selects ${stubs.stopping} "a busy lock"
        kill "$holder"
        wait "$holder" || :
        warned "the Codex daemon operation lock stayed busy for 1s"
        [ -e "$CODEX_HOME/stopped" ] || fail "a busy lock skipped the stop"

        timeout 120 ${root}/bin/codex app-server daemon stop < /dev/null > /dev/null 2>&1 || :
        pkill -f "$TMPDIR" || :
        echo "ok: Home Manager pins, keeps, retargets and releases the Codex daemon, leaves a foreign selection alone, and only warns when the lock stays busy or a stop fails or hangs" > "$out"
      '';
  };
}
