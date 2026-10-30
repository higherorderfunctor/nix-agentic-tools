# A runtime's launcher: a wrapper that execs the original package, or the bare
# package when there is nothing to bake in. Decided by ONE condition here, so
# no backend re-derives its own `needsWrapper` and drifts from the other — the
# failure the copilot wrapper's header records having shipped twice.
#
# Configured environmentVariables beat the ambient session. Environment
# defaults (network proxies) preserve it, including an explicit empty value.
# `flags` (`--add-flags …`) come before the environment, the order the
# wrappers this replaced used. The preflight follows environment injection,
# isolated by ./launcher-preflight.nix.
# `launcherPackage` flattens a previously generated launcher: one preflight
# and one exec of the package binary, even when a module selects a launcher.
pkgs: {
  # Executable followed by shell words, placed before the original command.
  # A supervising prefix owns launch-scoped files until the runtime exits.
  commandPrefix ? [],
  environmentDefaults ? {},
  environmentVariables ? {},
  exe,
  flags ? [],
  name,
  package,
  preflight ? null,
}: let
  inherit (pkgs) lib;
  unwrapped = package.launcherPackage or package;
  command = "${unwrapped}/bin/${exe}";
  defaults = import ./environment-defaults.nix {inherit lib;} environmentDefaults;
  args =
    lib.optional (commandPrefix != []) "--add-flags ${lib.escapeShellArg (lib.concatStringsSep " " (builtins.tail commandPrefix ++ [(lib.escapeShellArg command)]))}"
    ++ flags
    ++ lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") environmentVariables
    ++ lib.optional (defaults != "") "--run ${lib.escapeShellArg defaults}"
    ++ lib.optional (preflight != null) (import ./launcher-preflight.nix pkgs preflight);
in
  if args == []
  then package
  else
    pkgs.symlinkJoin {
      inherit name;
      paths = [unwrapped];
      # `launcherPackage` lets a consumer that selects this launcher as its
      # package, Codex's daemon selector and install flattening among them,
      # recover the original package.
      passthru = (unwrapped.passthru or {}) // {launcherPackage = unwrapped;};
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Replace the joined symlink; the prefix, if present, owns the command.
        ${pkgs.coreutils}/bin/rm "$out/bin/${exe}"
        makeWrapper ${
          if commandPrefix == []
          then command
          else builtins.head commandPrefix
        } "$out/bin/${exe}" \
          --run 'set -euETo pipefail; shopt -s inherit_errexit 2>/dev/null || :' \
          ${lib.concatStringsSep " " args}
      '';
    }
