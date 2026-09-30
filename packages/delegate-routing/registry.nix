{facetOwner, ...}: {
  documentation.skillDescriptions.delegate-routing = "Size model and effort before calling subagents or building workflows";
  fragments.categories.delegate-routing = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "development";
      }
    ];
  };
  update.excludePatterns = ["^delegate-routing-content$"];
}
