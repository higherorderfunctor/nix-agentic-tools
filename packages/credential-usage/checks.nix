{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  credentialUsageModule = (import ./lib/default.nix).ai.credential-usage.pythonModule {inherit pkgs python-stack;};
  usagePython = python-stack.withPackages (ps: [ps.pydantic ps.urllib3 credentialUsageModule]);
  strict = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
in {
  checks = {
    credential-usage-runner = pkgs.runCommand "credential-usage-runner" {nativeBuildInputs = [usagePython];} ''
      ${strict}
      python3 -I -B ${./checks/runner}/test_runner.py
      touch "$out"
    '';
    credential-usage-types = pkgs.runCommand "credential-usage-types" {nativeBuildInputs = [pkgs.pyright usagePython];} ''
      ${strict}
      pyright --project ${./python} --pythonpath "$(command -v python3)"
      touch "$out"
    '';
  };
}
