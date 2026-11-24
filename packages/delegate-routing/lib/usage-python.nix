# Build the routing helper and check interpreters from the same package set.
# Only the routing-plan suite needs Hypothesis, and it uses the generic runner.
{pkgs}: let
  inherit (pkgs.ai.generic) python-stack;
  cpaUsageModule = (import ../../cliproxyapi/lib/default.nix {inherit (pkgs) lib;}).ai.cliproxyapi.pythonModule {inherit pkgs python-stack;};
  credentialUsageModule = (import ../../credential-usage/lib/default.nix).ai.credential-usage.pythonModule {inherit pkgs python-stack;};
  runnerPackages = ps: [ps.pydantic ps.urllib3 credentialUsageModule];
in {
  routingTestPython = python-stack.withPackages (ps: runnerPackages ps ++ [ps.hypothesis]);
  usagePython = python-stack.withPackages (ps: runnerPackages ps ++ [cpaUsageModule]);
}
