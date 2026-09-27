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
# releases a store selection, so upstream's own first-start copy takes over.
#
# The retarget comes BEFORE the stop: `stop` finds the process by its pid
# file, not through `current`, and a launch racing in after the retarget
# already starts the new package. It is a stop and never a restart. A restart
# from here would give every later session a daemon holding the activation
# environment; the next launch that needs one starts it with the user's.
pkgs:
pkgs.writeShellApplication {
  name = "codex-daemon-select";
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  runtimeInputs = [pkgs.coreutils];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :

    codex_home="$1"
    target="''${2-}"
    root="$codex_home/packages/app-server-daemon"
    current="$root/current"

    previous=""
    if [ -L "$current" ]; then
      previous="$(readlink "$current")"
    elif [ -e "$current" ]; then
      echo "ERROR: refusing to replace $current: it is not a symlink" >&2
      false
    fi

    # A daemon that will not stop keeps serving the old package, which is
    # stale rather than broken, so it must not fail the whole activation.
    # `stop` waits for in-flight turns for up to shutdownGraceSeconds (at most
    # 300) before it returns.
    stop_daemon() {
      if ! CODEX_HOME="$codex_home" timeout 330 "$1" app-server daemon stop < /dev/null > /dev/null; then
        echo "warning: could not stop the Codex app-server daemon; it keeps running $previous until it is stopped" >&2
      fi
    }

    if [ -z "$target" ]; then
      case "$previous" in
        ${builtins.storeDir}/*)
          rm -f -- "$current"
          if [ -x "$previous/bin/codex" ]; then
            stop_daemon "$previous/bin/codex"
          fi
          ;;
      esac
      exit 0
    fi

    # The updater's eligibility marker, left by an earlier upstream-managed
    # selection. It names a release, never a store path.
    rm -f -- "$root/auto-update-version"
    if [ "$previous" = "$target" ]; then
      exit 0
    fi
    mkdir -p -- "$root"
    ln -sfn -- "$target" "$root/.current.nix"
    mv -Tf -- "$root/.current.nix" "$current"
    if [ -n "$previous" ]; then
      stop_daemon "$target/bin/codex"
    fi
  '';
}
