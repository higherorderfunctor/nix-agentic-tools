# `ai.jail`'s `wrap` run live on a CI runner, with nothing excluded: it proves
# only that the launcher literally runs inside bubblewrap. bubblewrap cannot
# run inside the Nix build sandbox on CI, sandboxed or `__noChroot`, so the
# check only builds this script and ci.yml's `jail-smoke` job runs it. The
# evidence holds for any jail profile: the jail's fresh /proc lists only its
# own processes, while the same probe outside lists the runner's. There is no
# structural fallback: if bubblewrap cannot run, the jailed probe fails and so
# does the script.
{
  lib,
  pkgs,
  self,
  ...
}: let
  jailLib = import ../../lib/ai/jail {inherit lib;};
  strictShellApplication = import ../../lib/strict-shell-application.nix pkgs;
  # Counts /proc's process entries with a glob in this shell, because a
  # subprocess would be one more entry. An empty list means /proc was not
  # readable, so the probe fails instead of reporting a count.
  probe = strictShellApplication {
    name = "jail-smoke-probe";
    text = ''
      shopt -s nullglob
      entries=(/proc/[0-9]*)
      if [ "''${#entries[@]}" -eq 0 ]; then
        echo "jail-smoke-probe: /proc lists no process, not even this one" >&2
        exit 1
      fi
      echo "''${#entries[@]}"
    '';
  };
  jailed = jailLib.wrap {
    executables = ["jail-smoke-probe"];
    jail = self.lib.ai.jail;
    name = "jail-smoke-probe";
    package = probe;
    inherit pkgs;
    profile = {
      exclude = {
        environment = [];
        paths = [];
      };
      permissions = null;
    };
  };
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    ai-jail-live = strictShellApplication {
      name = "ai-jail-live";
      # The jail's pid namespace holds bubblewrap's pid-1 reaper and the probe,
      # so it lists at most 2; outside, more than 2 is the positive control. A
      # value that is not a number makes the test error, which takes `else`.
      text = ''
        if ! outside="$(${lib.getExe probe})"; then
          echo "FAIL: the probe failed outside the jail" >&2
          exit 1
        fi
        if ! inside="$(${jailed}/bin/jail-smoke-probe)"; then
          echo "FAIL: the jailed probe exited non-zero" >&2
          exit 1
        fi
        if [ "$outside" -gt 2 ] && [ "$inside" -le 2 ]; then
          echo "AI-JAIL-LIVE: the jailed probe's /proc lists $inside processes; outside, $outside"
        else
          echo "FAIL: /proc lists $inside processes in the jail and $outside outside; a fresh pid namespace lists at most 2, the runner more" >&2
          exit 1
        fi
      '';
    };
  };
}
