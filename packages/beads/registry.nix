{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.devToolDescriptions.beads = "Graph-based issue tracker for AI coding agents";
  # beads: the contained devenv lifecycle, serialized checkpoint protocol,
  # and sole raw-Dolt publication boundary.
  fragments.categories.beads = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "beads-lifecycle";
        dir = facetOwner;
      }
    ];
  };
  update.targets.beads = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/beads/package.nix)];};
}
