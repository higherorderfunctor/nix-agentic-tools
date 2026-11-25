# The registered Claude Reader, run as the installed command, sends its pair's requests and prints its pair's results.
{pkgs, ...}: let
  inherit (pkgs) lib;
  inherit (pkgs.ai.generic) python-stack;
  credentialUsage = (import ../../credential-usage/lib/default.nix).ai.credential-usage;
  inherit ((import ../lib/default.nix).ai.claude-code) usageModule usageReader;
  reader =
    (credentialUsage.mergeReaders {inherit pkgs lib;} {
      contributions = [usageModule];
    }).claude.package;
  python = python-stack.withPackages (ps: [
    ps.pydantic
    ps.urllib3
    (credentialUsage.pythonModule {inherit pkgs python-stack;})
  ]);
  # Direct cases have a fixed vendor origin. Fail any attempted socket before
  # the Reader can swallow the failure or contact that origin.
  offline = python-stack.pkgs.toPythonModule (pkgs.symlinkJoin {
    name = "claude-usage-offline";
    paths = [
      (pkgs.writeTextDir "${python-stack.sitePackages}/reader_offline.pth" "import reader_offline\n")
      (pkgs.writeTextDir "${python-stack.sitePackages}/reader_offline.py" ''
        import os
        import sys

        def reject_socket(event, _args):
            if event in {"socket.connect", "socket.getaddrinfo", "socket.sendmsg", "socket.sendto"}:
                os._exit(97)

        sys.addaudithook(reject_socket)
      '')
    ];
  });
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
      python3 -I -B ${../../credential-usage/checks/conformance}/standalone.py ${../usage/cases} ${lib.getExe reader} ${lib.getExe directReader}
      touch "$out"
    '';
}
