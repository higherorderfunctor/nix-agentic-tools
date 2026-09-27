# Selects the package Codex's shared app-server daemon runs, from Home Manager
# activation. Imported by mkCodex.nix and by the runtime check that drives it
# against the real package, so both exercise one script.
#
# Codex runs its daemon from `$CODEX_HOME/packages/app-server-daemon/current`
# and never from the CLI that launched it (codex-rs/app-server-daemon,
# managed_install.rs, rust-v0.157.1). Left alone, the first start copies the
# invoking package into `releases/` and its updater then replaces it hourly
# from GitHub, so the daemon never follows a Nix bump. Pointing `current`
# straight at the store package avoids both: a selection outside `releases/`
# with no `auto-update-version` marker never qualifies for the updater, and a
# selection that exists is never copied again.
#
# Arguments: the Codex home, then the package root to select. An empty root
# releases a store selection this module made, so upstream's own first-start
# copy takes over.
#
# The selection is made under upstream's daemon operation lock, the one every
# lifecycle command and the first-start copy hold while they read or publish
# `current` (lib.rs `acquire_operation_lock`, a `flock` on
# `app-server-daemon/daemon.lock`). Without it, a start already copying the
# package could publish its copy over ours. The lock is released before the
# stop, because `stop` takes it too.
#
# The retarget comes BEFORE the stop: `stop` finds the process by its pid
# file, not through `current`, and a launch racing in after the retarget
# already starts the new package. It is a stop and never a restart. A restart
# from here would give every later session a daemon holding the activation
# environment; the next launch that needs one starts it with the user's.
pkgs: let
  inherit (pkgs) lib;
  # The only selection this module writes: `<store package>/<root>`, the root
  # packageLayout.nix names. A `current` of any other shape, a
  # home-manager-files link included, belongs to someone else and is left
  # alone.
  ownedSelection = "^${lib.escapeRegex builtins.storeDir}/[^/]+/${lib.escapeRegex (import ./packageLayout.nix).root}$";
  # The selector's whole worst case has to fit in activation's time limit. The
  # tightest is Home Manager's NixOS module, whose unit gives ALL of activation
  # `TimeoutStartSec = 5m`; a selector that outlives it gets the unit killed,
  # which fails the switch and skips every later entry. nix-darwin and a
  # standalone `home-manager switch` set no limit. This takes under half of
  # the 5 minutes, leaving the rest to every other entry.
  activationBudgetSeconds = 120;
  # A stop still running after `--kill-after` more seconds is sent SIGKILL.
  stopKillSeconds = 5;
in
  # `.override` exists for chatgpt-codex-daemon-selection only, which shortens
  # both waits to drive their warnings in seconds.
  lib.makeOverridable ({
    # How long activation waits for another lifecycle command to release the
    # operation lock before it selects without it. Every holder is short-lived:
    # a start, a stop, a restart or an updater tick.
    selectLockSeconds ? 20,
    # Upstream's stop waits for the operation lock, sends SIGTERM, waits the
    # daemon's `shutdown_grace_seconds` (60 by default) and then sends SIGKILL
    # and waits 10s more (codex-rs/app-server-daemon, rust-v0.157.1:
    # settings.rs, backend/pid.rs). A default stop therefore fits in this
    # bound. A user who raised the grace toward upstream's 300s maximum can
    # outlast it; `timeout` then ends only the CLI, and the warning says so.
    stopTimeoutSeconds ? 90,
  }:
    assert lib.assertMsg (selectLockSeconds + stopTimeoutSeconds + stopKillSeconds <= activationBudgetSeconds)
    "codex-daemon-select: waiting ${toString selectLockSeconds}s for the lock and ${toString (stopTimeoutSeconds + stopKillSeconds)}s for the stop exceeds its ${toString activationBudgetSeconds}s activation budget";
      pkgs.writeShellApplication {
        name = "codex-daemon-select";
        bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
        runtimeInputs = [pkgs.coreutils pkgs.flock];
        text = ''
          shopt -s inherit_errexit 2>/dev/null || :

          codex_home="$1"
          target="''${2-}"
          root="$codex_home/packages/app-server-daemon"
          current="$root/current"
          state="$codex_home/app-server-daemon"
          owned_selection=${lib.escapeShellArg ownedSelection}

          # Nothing selected and nothing to select: leave no trace, not even the
          # lock file, in a home that never ran the daemon.
          if [ -z "$target" ] && [ ! -L "$current" ] && [ ! -e "$current" ]; then
            exit 0
          fi

          ${pkgs.coreutils}/bin/mkdir -p -- "$state"
          exec 9>> "$state/daemon.lock"
          if ! ${pkgs.flock}/bin/flock -w ${toString selectLockSeconds} 9; then
            echo "warning: the Codex daemon operation lock stayed busy for ${toString selectLockSeconds}s; selecting the daemon package without it" >&2
          fi

          previous=""
          if [ -L "$current" ]; then
            previous="$(${pkgs.coreutils}/bin/readlink "$current")"
          elif [ -e "$current" ]; then
            echo "ERROR: refusing to replace $current: it is not a symlink" >&2
            false
          fi

          stop_with=""
          if [ -z "$target" ]; then
            if [[ $previous =~ $owned_selection ]]; then
              ${pkgs.coreutils}/bin/rm -f -- "$current"
              if [ -x "$previous/bin/codex" ]; then
                stop_with="$previous/bin/codex"
              fi
            fi
          else
            # The updater's eligibility marker, left by an earlier upstream-managed
            # selection. It names a release, never a store path.
            ${pkgs.coreutils}/bin/rm -f -- "$root/auto-update-version"
            if [ "$previous" != "$target" ]; then
              ${pkgs.coreutils}/bin/mkdir -p -- "$root"
              ${pkgs.coreutils}/bin/ln -sfn -- "$target" "$root/.current.nix"
              ${pkgs.coreutils}/bin/mv -Tf -- "$root/.current.nix" "$current"
              if [ -n "$previous" ]; then
                stop_with="$target/bin/codex"
              fi
            fi
          fi
          exec 9>&-

          # A daemon that will not stop keeps serving the old package, which is
          # stale rather than broken, so this warns and never fails activation.
          # Only a changed target stops, so nothing retries it: the warning is the
          # only signal. A stop ended while still waiting for the operation lock
          # never signalled the daemon; one ended after its SIGTERM leaves the
          # daemon to exit on its own. Either way it may still be running, and the
          # warning names the command that stops it.
          if [ -n "$stop_with" ]; then
            status=0
            CODEX_HOME="$codex_home" ${pkgs.coreutils}/bin/timeout --kill-after=${toString stopKillSeconds} ${toString stopTimeoutSeconds} \
              "$stop_with" app-server daemon stop < /dev/null > /dev/null || status=$?
            if [ "$status" -ne 0 ]; then
              if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
                reason="did not finish within ${toString stopTimeoutSeconds}s"
              else
                reason="failed with exit status $status"
              fi
              printf 'warning: stopping the Codex app-server daemon %s; it may still be running %s until it exits. Stop it with: CODEX_HOME=%q %q app-server daemon stop\n' \
                "$reason" "$previous" "$codex_home" "$stop_with" >&2
            fi
          fi
        '';
      }) {}
