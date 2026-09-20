{facetOwner, ...}: {
  documentation.skillDescriptions.delegate-sizing = "Size model and effort before calling subagents or building workflows";
  fragments.categories.delegate-sizing = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "development";
      }
    ];
  };
  update.excludePatterns = ["^delegate-sizing-content$"];
}
