# The committed packages/git-revise/extracted.json, and the extractor that
# produces it (lib/git-tool-settings/extraction.nix builds all three):
#
#   git-revise-extracted          drift: the committed sidecar equals a fresh
#                                 extraction of the pinned source. Blocking,
#                                 because the typed options are generated
#                                 from the committed file.
#   git-revise-extractor-guards   the extractor fails closed: every mutant in
#                                 extractor-mutants.nix trips the guards it
#                                 names or moves the output as it says.
#   git-revise-extracted-binary   every key the census reports is a string in
#                                 the installed Python package.
{
  gitToolExtraction,
  pkgs,
  self,
  ...
}: {
  checks = (gitToolExtraction {inherit pkgs;}).checks {
    name = "git-revise";
    package = self.packages.${pkgs.stdenv.hostPlatform.system}.git-revise;
    sidecar = "packages/git-revise/extracted.json";
    committed = ../extracted.json;
    extractDir = ../extract;
    mutants = import ./extractor-mutants.nix;
    installed = "lib";
  };
}
