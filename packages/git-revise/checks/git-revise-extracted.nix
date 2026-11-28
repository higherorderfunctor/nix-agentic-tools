# lib/git-tool-settings/extraction.nix builds three checks with distinct inputs:
#
#   git-revise-extracted          Reject a stale committed sidecar (the input to
#                                 typed options) and invalid hand-written rows
#                                 against a fresh extraction of pinned source.
#   git-revise-extracted-binary   Catch keys reported by the census but absent
#                                 from the installed Python package, even if
#                                 the committed and fresh extractions agree.
#   git-revise-extractor-guards   Catch lost source recognition that the pinned
#                                 source does not exercise. Each mutant names
#                                 the guard or exact output it expects.
{
  gitToolExtraction,
  pkgs,
  self,
  ...
}: {
  checks = (gitToolExtraction {inherit pkgs;}).checks {
    name = "git-revise";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.git-revise;
    dir = ../extracted;
    extractDir = ../extract;
    mutants = import ./extractor-mutants.nix;
    installed = "lib";
  };
}
