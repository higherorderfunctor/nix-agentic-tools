# PROTOTYPE. The pinned Kimchi release's network targets, extracted with
# CodeQL (lib/extracted/codeql). Not yet a fact: nothing reads this output,
# and no facts.json row declares it. It runs on x86_64-linux only, the one
# platform with a per-language CodeQL bundle.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    kimchi-codeql-network-targets = (extractedLib {inherit pkgs;}).codeql.networkTargets {
      name = "kimchi-codeql-network-targets";
      # The GitHub release archive Kimchi's own extraction reads.
      src = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru.extractionSources.kimchi;
    };
  };
}
