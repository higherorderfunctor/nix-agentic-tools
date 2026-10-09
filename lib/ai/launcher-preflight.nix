# The advisory check a launcher runs before it execs its runtime, as the one
# makeWrapper `--run` argument every launcher shares, so no launcher re-derives
# the isolation. `timeout` bounds it to one second and, run without
# `--foreground`, kills the check's whole process group. Stdin comes from
# /dev/null, so a check can neither consume the runtime's input nor stop on a
# terminal read from timeout's background group. Stdout is discarded, so the
# runtime's output is untouched. `|| :` keeps a failure or timeout from
# changing the launch. Warnings reach the user on stderr.
pkgs: preflight: "--run ${pkgs.lib.escapeShellArg "${pkgs.coreutils}/bin/timeout --kill-after=0.1 1 ${pkgs.lib.getExe preflight} \"$@\" </dev/null >/dev/null || :"}"
