# Package recipes and checks share strict patch flags through source, stdenv
# attributes and shell commands. Git handles the pnpm patches GNU cannot read.
{pkgs}: let
  inherit (pkgs) lib;
  flags = ["-p1" "--fuzz=0" "--no-backup-if-mismatch"];
  attrs = args: args // {patchFlags = flags;};
in {
  inherit attrs;
  source = args: pkgs.applyPatches (attrs args);

  command = {
    directory ? ".",
    gitArgs ? null,
    patchFiles,
  }: let
    apply = file:
      if gitArgs == null
      then "${pkgs.patch}/bin/patch ${lib.escapeShellArgs flags} < ${lib.escapeShellArg file}"
      else "${pkgs.git}/bin/git apply ${lib.escapeShellArgs ([(builtins.head flags)] ++ gitArgs)} -- ${lib.escapeShellArg file}";
  in ''
    (
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cd ${lib.escapeShellArg directory}
      ${lib.concatMapStringsSep "\n" apply patchFiles}
    )
  '';
}
