{facetOwner, ...}: {
  checks.cacheHitParity.git-branchless = {consumerPath = ["ai" "gitTools" "git-branchless"];};
  documentation.gitToolDescriptions.git-branchless = "Anonymous branching, in-memory rebases";
  # The config-key extractor, its guards, the sidecar and the typed-option
  # generator.
  fragments.categories.git-branchless = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "extraction";
      }
    ];
  };
}
