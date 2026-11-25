# Exercise the installed Reader module against public envelopes and process captures.
# Validate the published schema independently against the example and each successful golden.
{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  credentialUsageModule = (import ./lib/default.nix).ai.credential-usage.pythonModule {inherit pkgs python-stack;};
  usagePackages = ps: [ps.pydantic ps.urllib3 credentialUsageModule];
  usagePython = python-stack.withPackages usagePackages;
  synthetic = (import ./lib/default.nix).ai.credential-usage.conformanceCheck {
    inherit pkgs python-stack;
    name = "credential-usage-conformance";
    ownerModules = [];
    pair = ./checks/conformance/synthetic/cases;
    entry = "synthetic.cli:main";
  };
  strict = ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
  '';
in {
  checks = {
    credential-usage-conformance = synthetic.overrideAttrs (old: {
      buildCommand =
        old.buildCommand
        + ''
          python3 -I -B ${./checks/conformance}/test_conformance.py -v SuiteTests
        '';
    });
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
        nativeBuildInputs = [pkgs.biome pkgs.pyright (python-stack.withPackages (ps: usagePackages ps ++ [ps.jsonschema]))];
        USAGE_DOC = ./docs/credential-usage.md;
      } ''
        ${strict}
        pyright --project ${./checks}/schema --pythonpath "$(command -v python3)"
        python3 -I -B ${./checks/schema/generate_schema.py} > schema.json
        diff -u ${./schema/usage-envelope.schema.json} schema.json
        python3 -I -B ${./checks}/schema/validate_schema.py ${./schema/usage-envelope.schema.json} \
          ${(import ../claude-code/lib/default.nix).ai.claude-code.usagePair} ${./checks/conformance/synthetic/cases}
        touch "$out"
      '';
    credential-usage-types = pkgs.runCommand "credential-usage-types" {nativeBuildInputs = [pkgs.pyright synthetic.python];} ''
      ${strict}
      pyright --project ${./python} --pythonpath "$(command -v python3)"
      pyright --project ${./checks/conformance} --pythonpath "$(command -v python3)"
      touch "$out"
    '';
  };
  imports = [./checks/registration.nix];
}
