# A runtime's launcher: the package wrapped with `wrapProgram`, or the bare
# package when there is nothing to deliver. Decided by ONE condition here, so
# no backend re-derives its own `needsWrapper` and drifts from the other — the
# failure the copilot wrapper's header records having shipped twice.
#
# One `--run` materializes the whole environment at launch. Literals still beat
# the ambient session, while references are read without putting their values
# in the store.
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
  rv = import ../runtime-values {inherit lib;};
  args =
    flags
    ++ lib.optional (environmentVariables != {}) "--run ${lib.escapeShellArg (rv.environment {
      inherit pkgs;
      values = environmentVariables;
      path = [name];
    })}";
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
