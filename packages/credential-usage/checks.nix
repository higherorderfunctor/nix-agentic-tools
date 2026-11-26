# Exercise the installed Reader module against public envelopes and process captures.
{pkgs, ...}: let
  inherit (pkgs.ai.generic) python-stack;
  credentialUsage = (import ./lib/default.nix).ai.credential-usage;
  conformance = credentialUsage.conformanceCheck {
    inherit pkgs python-stack;
    name = "credential-usage-conformance";
    ownerModules = [];
    pair = ./checks/conformance/synthetic/cases;
    entry = "synthetic.cli:main";
  };
  # Each check runs one script in the conformance interpreter, with `settings` as its derivation attributes.
  check = name: settings: script:
    pkgs.runCommand "credential-usage-${name}" (settings // {nativeBuildInputs = [conformance.python] ++ settings.nativeBuildInputs or [];})
    ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${script}
      touch "$out"
    '';
in {
  checks = {
    credential-usage-conformance = conformance;
    credential-usage-contract = check "contract" {USAGE_DOC = ./docs/credential-usage.md;} ''
      python3 -I -B ${./checks/contract}/test_envelope.py -v
    '';
    credential-usage-runner = check "runner" {} ''
      python3 -I -B ${./checks/runner}/test_runner.py
    '';
    credential-usage-schema = check "schema" {nativeBuildInputs = [pkgs.biome];} ''
      python3 -I -B ${./checks/schema}/generate_schema.py > schema.json
      diff -u ${./schema/usage-envelope.schema.json} schema.json
    '';
    credential-usage-types = check "types" {nativeBuildInputs = [pkgs.pyright];} ''
      pyright --project ${./python} --pythonpath "$(command -v python3)"
      pyright --project ${./checks/conformance} --pythonpath "$(command -v python3)"
    '';
  };
  imports = [./checks/registration.nix];
}
