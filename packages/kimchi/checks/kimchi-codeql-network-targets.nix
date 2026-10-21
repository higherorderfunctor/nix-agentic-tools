# PROTOTYPE. The pinned Kimchi release's network targets, extracted with
# CodeQL (lib/extracted/codeql). Not yet a fact: nothing reads this output,
# and no facts.json row declares it. It runs on x86_64-linux only, the one
# platform with a per-language CodeQL bundle. Unpublished: the CodeQL Terms
# forbid distributing the CLI, so no cache may receive its build closure.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  name = "kimchi-codeql-network-targets";
  supported = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
in {
  checks = lib.optionalAttrs supported {
    ${name} = (extractedLib {inherit pkgs;}).codeql.networkTargets {
      inherit name;
      # The GitHub release archive Kimchi's own extraction reads.
      src = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru.extractionSources.kimchi;
    };
  };
  unpublishedChecks = lib.optional supported name;
}
