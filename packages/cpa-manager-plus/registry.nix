{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.genericDescriptions.cpa-manager-plus = "CPA Manager Plus dashboard and management server";
  fragments.categories.cpa-manager-plus = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "cpa-manager-plus-extraction";
      }
    ];
  };
  update.targets.cpa-manager-plus = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/cpa-manager-plus/package.nix)];};
}
