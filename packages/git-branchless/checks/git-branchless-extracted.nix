# The committed packages/git-branchless/extracted.json, and the extractor
# that produces it (lib/git-tool-settings/extraction.nix builds all three):
#
#   git-branchless-extracted          drift: the committed sidecar equals a
#                                     fresh extraction of the pinned, patched
#                                     source. Blocking, because the typed
#                                     options are generated from the
#                                     committed file.
#   git-branchless-extractor-guards   the extractor fails closed: every
#                                     mutant in extractor-mutants.nix either
#                                     trips the guards it names or moves the
#                                     output exactly as it says.
#   git-branchless-extracted-binary   every key the census reports is a
#                                     string in the built binary.
{
  gitToolExtraction,
  pkgs,
  self,
  ...
}: {
  checks = (gitToolExtraction {inherit pkgs;}).checks {
    name = "git-branchless";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.git-branchless;
    sidecar = "packages/git-branchless/extracted.json";
    committed = ../extracted.json;
    extractDir = ../extract;
    mutants = import ./extractor-mutants.nix;
    installed = "bin/git-branchless";
  };
}
