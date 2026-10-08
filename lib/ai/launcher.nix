# A runtime's launcher: a wrapper that execs the original package, or the bare
# package when there is nothing to bake in. Decided by ONE condition here, so
# no backend re-derives its own `needsWrapper` and drifts from the other — the
# failure the copilot wrapper's header records having shipped twice.
#
# `--set`, never `--set-default`: a configured value must beat the ambient
# session, and `--set-default` is reserved for polite defaults (`TERM`).
# `flags` (`--add-flags …`) come before the environment, the order the
# wrappers this replaced used. The preflight follows environment injection.
# `launcherPackage` flattens a previously generated launcher: one preflight
# and one exec of the package binary, even when a module selects a launcher.
pkgs: {
  environmentVariables ? {},
  exe,
  flags ? [],
  name,
  package,
  preflight ? null,
}: let
  inherit (pkgs) lib;
  unwrapped = package.launcherPackage or package;
  args =
    flags
    ++ lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") environmentVariables
    ++ lib.optional (preflight != null) "--run ${lib.escapeShellArg "${lib.getExe preflight} \"$@\" >/dev/null || :"}";
in
  if args == []
  then package
  else
    pkgs.symlinkJoin {
      inherit name;
      paths = [unwrapped];
      # Preserve package metadata used by Codex's daemon selector when a
      # consumer selects this launcher as its package.
      passthru = (unwrapped.passthru or {}) // {launcherPackage = unwrapped;};
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Replace the joined symlink; makeWrapper execs the original directly.
        ${pkgs.coreutils}/bin/rm "$out/bin/${exe}"
        makeWrapper ${unwrapped}/bin/${exe} "$out/bin/${exe}" \
          --run 'set -euETo pipefail; shopt -s inherit_errexit 2>/dev/null || :' \
          ${lib.concatStringsSep " " args}
      '';
    }
