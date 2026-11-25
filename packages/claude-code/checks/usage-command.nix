# The registered Claude Reader, run as the installed command, sends its pair's requests and prints its pair's results.
{pkgs, ...}: let
  inherit (pkgs) lib;
  inherit (pkgs.ai.generic) python-stack;
  credentialUsage = (import ../../credential-usage/lib/default.nix).ai.credential-usage;
  claude = import ../lib/default.nix;
  inherit (claude.ai.claude-code) usageModule usagePair usageReader;
  reader =
    (credentialUsage.mergeReaders {inherit pkgs lib;} {
      contributions = [usageModule];
    }).claude.package;
  python = python-stack.withPackages (ps: [
    ps.pydantic
    ps.urllib3
    (credentialUsage.pythonModule {inherit pkgs python-stack;})
    (claude.ai.claude-code.pythonModule {inherit pkgs python-stack;})
    ((import ../../cliproxyapi/lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule {inherit pkgs python-stack;})
  ]);
  # Install the socket guard even in a probe interpreter without replay dependencies.
  guard = pkgs.writeText "reader-offline.py" ''
    import os
    import sys
    def reject_socket(event, _):
        if event in {"socket.connect", "socket.getaddrinfo", "socket.sendmsg", "socket.sendto"}:
            os._exit(97)
    sys.addaudithook(reject_socket)
  '';
  offline = python-stack.pkgs.toPythonModule (
    pkgs.writeTextDir "${python-stack.sitePackages}/reader_offline.pth" ''
      import os, runpy; runpy.run_path("${guard}"); os.getenv("USAGE_DIRECT_REPLAY") and runpy.run_path("${credentialUsage.standaloneCheck}")["install_direct_replay"](2, 0.375)
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
    direct.policy = {
      retries = 2;
      timeout = 0.375;
    };
  };
in {
  checks.claude-code-usage-command =
    pkgs.runCommand "claude-code-usage-command" {
      nativeBuildInputs = [pkgs.bash python];
      USAGE_PAIR = usagePair;
      USAGE_SUITE = credentialUsage.conformanceSuite;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 -I -B ${./usage-deadline}/test_deadline.py
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
