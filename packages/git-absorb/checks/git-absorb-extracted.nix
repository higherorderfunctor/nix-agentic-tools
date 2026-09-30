# The committed packages/git-absorb/extracted.json, and the extractor that
# produces it (lib/git-tool-settings/extraction.nix builds all three):
#
#   git-absorb-extracted          drift: the committed sidecar equals a fresh
#                                 extraction of the pinned source. Blocking,
#                                 because the typed options are generated
#                                 from the committed file.
#   git-absorb-extractor-guards   the extractor fails closed: every mutant in
#                                 extractor-mutants.nix trips the guards it
#                                 names or moves the output as it says.
#   git-absorb-extracted-binary   every key the census reports is a string in
#                                 the built binary.
{
  gitToolExtraction,
  pkgs,
  self,
  ...
}: {
  checks = (gitToolExtraction {inherit pkgs;}).checks {
    name = "git-absorb";
    package = self.packages.${pkgs.stdenv.hostPlatform.system}.git-absorb;
    sidecar = "packages/git-absorb/extracted.json";
    committed = ../extracted.json;
    extractDir = ../extract;
    mutants = import ./extractor-mutants.nix;
    installed = "bin/git-absorb";
  };
}
