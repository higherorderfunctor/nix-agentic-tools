# Exercise the installed Reader module against public envelopes and process captures.
# Schema equality and model validation of the documented bytes use the same contract.
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
    credential-usage-contract =
      pkgs.runCommand "credential-usage-contract" {
        nativeBuildInputs = [usagePython];
        USAGE_DOC = ./docs/credential-usage.md;
      } ''
        ${strict}
        python3 -I -B ${./checks/contract}/test_envelope.py -v
        touch "$out"
      '';
    credential-usage-runner = pkgs.runCommand "credential-usage-runner" {nativeBuildInputs = [usagePython];} ''
      ${strict}
      python3 -I -B ${./checks/runner}/test_runner.py
      touch "$out"
    '';
    credential-usage-schema =
      pkgs.runCommand "credential-usage-schema" {
        nativeBuildInputs = [pkgs.biome usagePython];
        USAGE_DOC = ./docs/credential-usage.md;
      } ''
        ${strict}
        python3 -I -B ${./checks/schema/generate_schema.py} > schema.json
        diff -u ${./schema/usage-envelope.schema.json} schema.json
        python3 -I -B ${./checks/contract}/test_envelope.py TestEnvelope.test_requires_supported_schema_version
        touch "$out"
      '';
    credential-usage-types = pkgs.runCommand "credential-usage-types" {nativeBuildInputs = [pkgs.pyright usagePython];} ''
      ${strict}
      pyright --project ${./python} --pythonpath "$(command -v python3)"
      touch "$out"
    '';
  };
}
