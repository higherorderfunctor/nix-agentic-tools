# The registered Claude Reader, run as the installed command, sends its pair's requests and prints its pair's results.
{pkgs, ...}: let
  inherit (pkgs) lib;
  inherit (pkgs.ai.generic) python-stack;
  credentialUsage = (import ../../credential-usage/lib/default.nix).ai.credential-usage;
  inherit ((import ../lib/default.nix).ai.claude-code) usageModule usagePair usageReader;
  reader =
    (credentialUsage.mergeReaders {inherit pkgs lib;} {
      contributions = [usageModule];
    }).claude.package;
  python = python-stack.withPackages (ps: [
    ps.pydantic
    ps.urllib3
    (credentialUsage.pythonModule {inherit pkgs python-stack;})
  ]);
  # Install the replay at startup, leaving the production origin and command intact.
  offline = python-stack.pkgs.toPythonModule (
    pkgs.writeTextDir "${python-stack.sitePackages}/reader_offline.pth" ''
      import runpy; runpy.run_path("${credentialUsage.standaloneCheck}")["install_direct_replay"](0, 75)
    ''
  );
  offlineStack =
    python-stack
    // {
      withPackages = select: python-stack.withPackages (ps: select ps ++ [offline]);
    };
  directReader = usageReader {
    inherit pkgs;
    python-stack = offlineStack;
    claude = pkgs.emptyDirectory;
  };
in {
  checks.claude-code-usage-command =
    pkgs.runCommand "claude-code-usage-command" {
      nativeBuildInputs = [pkgs.bash python];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      if ${offlineStack.withPackages (_: [])}/bin/python3 -I -c 'import socket; socket.getaddrinfo("example.invalid", 443)'; then
        echo "Direct Reader check: its offline guard did not stop the socket" >&2
        exit 1
      else
        test "$?" -eq 97
      fi
      python3 -I -B ${credentialUsage.standaloneCheck} ${usagePair} ${lib.getExe reader} ${lib.getExe directReader}
      touch "$out"
    '';
}
