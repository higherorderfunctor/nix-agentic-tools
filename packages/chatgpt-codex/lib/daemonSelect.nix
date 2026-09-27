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
  # Upstream's bounds (codex-rs/app-server-daemon, rust-v0.157.1):
  # MAX_SHUTDOWN_GRACE_SECONDS in settings.rs, OPERATION_LOCK_TIMEOUT in lib.rs.
  maxShutdownGraceSeconds = 300;
  operationLockSeconds = maxShutdownGraceSeconds + 75;
  # A stop first waits for the operation lock, then signals the daemon and
  # waits out its grace period. This bound outlasts both, so `timeout` only
  # ends a stop that hangs past upstream's own limits.
  stopTimeoutSeconds = operationLockSeconds + maxShutdownGraceSeconds + 30;
  # How long activation waits for another lifecycle command before it selects
  # without the lock. Every holder is short-lived: a start, a stop, a restart
  # or an updater tick.
  selectLockSeconds = 30;
  # The only selection this module writes: `<store package>/libexec/codex`,
  # package.nix's `packageRoot`. A `current` of any other shape, a
  # home-manager-files link included, belongs to someone else and is left
  # alone. chatgpt-codex-daemon-selection fails if the two ever disagree.
  ownedSelection = "^${lib.escapeRegex builtins.storeDir}/[^/]+/libexec/codex$";
in
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
      # only signal. A stop that failed while still waiting for the operation
      # lock never signalled the daemon at all.
      if [ -n "$stop_with" ]; then
        if ! CODEX_HOME="$codex_home" ${pkgs.coreutils}/bin/timeout ${toString stopTimeoutSeconds} "$stop_with" app-server daemon stop < /dev/null > /dev/null; then
          echo "warning: could not stop the Codex app-server daemon; it keeps running $previous until it is stopped" >&2
        fi
      fi
    '';
  }
