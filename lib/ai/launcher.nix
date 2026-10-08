# A runtime's launcher: the package wrapped with `wrapProgram`, or the bare
# package when there are no flags or environment exports. Decided by ONE condition here, so
# no backend re-derives its own `needsWrapper` and drifts from the other — the
# failure the copilot wrapper's header records having shipped twice.
#
# One runtime export block handles literals and references without putting
# referenced values in the store or argv. Configured values beat ambient ones.
pkgs: {
  environmentVariables ? {},
  exe,
  flags ? [],
  name,
  option,
  package,
}: let
  inherit (pkgs) lib;
  redact = import ../redact {inherit lib;};
  args =
    flags
    ++ lib.optional (environmentVariables != {}) "--run ${lib.escapeShellArg (redact.environment {
      inherit option pkgs;
      values = environmentVariables;
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
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        wrapProgram $out/bin/${exe} ${lib.concatStringsSep " " args}
      '';
    }
