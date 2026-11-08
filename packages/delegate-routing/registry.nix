{facetOwner, ...}: {
  documentation.skillDescriptions.delegate-routing = "Plan substantive work and validate sized delegate launches";
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
