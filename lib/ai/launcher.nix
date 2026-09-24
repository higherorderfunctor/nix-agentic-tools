# A runtime's launcher: the package wrapped with `wrapProgram`, or the bare
# package when there is nothing to bake in. Decided by ONE condition here, so
# no backend re-derives its own `needsWrapper` and drifts from the other — the
# failure the copilot wrapper's header records having shipped twice.
#
# `--set`, never `--set-default`: a configured value must beat the ambient
# session, and `--set-default` is reserved for polite defaults (`TERM`).
# `flags` (`--add-flags …`) come before the environment, the order the
# wrappers this replaced used, so their store paths are unchanged.
pkgs: {
  environmentVariables ? {},
  exe,
  flags ? [],
  name,
  package,
}: let
  inherit (pkgs) lib;
  args =
    flags
    ++ lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") environmentVariables;
in
  if args == []
  then package
  else
    pkgs.symlinkJoin {
      inherit name;
      paths = [package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/${exe} ${lib.concatStringsSep " " args}
      '';
    }
