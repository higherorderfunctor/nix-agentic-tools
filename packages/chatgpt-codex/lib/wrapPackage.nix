# Codex launcher wrapper — process-environment bake.
#
# This is the FIRST wrapper this package has had. Until `ai.shell` there was
# nothing to wrap for, so `defaults.package` handed the upstream derivation
# through untouched; both backends still do exactly that whenever the
# argument set below is empty, so a Codex with no shell set keeps the same
# store path it had before this file existed.
#
# Why a wrapper is unavoidable here. Codex takes its command shell from
# `SHELL` in its OWN process environment (via `portable_pty`), and it has
# neither a dedicated variable like Claude's `CLAUDE_CODE_SHELL` nor a
# `config.toml` key for it. `shell_environment_policy` is NOT that key — it
# filters what SPAWNED commands inherit, which is a different thing, and
# writing the shell there would configure the children rather than Codex.
# That leaves the process environment, and the only place this repo can set
# it declaratively is the launcher.
#
# `--set` (clobber), not `--set-default`: this repo reserves `--set-default`
# for polite defaults a user may override in their own environment (`TERM`,
# `GH_TELEMETRY`). A configured shell is a config-driven value that must win
# over whatever the ambient session exports — which, on the machine that
# motivated this option, is the very shell being moved away from.
#
# Codex's fallback makes clobbering matter more than it looks: when `SHELL`
# is unset or not executable it falls back to the PASSWORD-DATABASE shell,
# so "not setting it" is not neutral — it lands on the login shell.
{
  lib,
  pkgs,
}: {
  package,
  environmentVariables ? {},
}: let
  setEnvArgs =
    lib.concatStringsSep " "
    (lib.mapAttrsToList
      (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}")
      environmentVariables);
in
  # Decided by ONE condition, in one place, so neither backend re-derives its
  # own `needsWrapper` and drifts from the other — the specific failure the
  # copilot wrapper's header records having shipped twice.
  if environmentVariables == {}
  then package
  else
    pkgs.symlinkJoin {
      name = "chatgpt-codex-wrapped";
      paths = [package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/codex ${setEnvArgs}
      '';
    }
