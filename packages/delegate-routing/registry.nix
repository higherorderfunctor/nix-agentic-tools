{facetOwner, ...}: {
  documentation.skillDescriptions.delegate-routing = "Classify capability independently and validate delegate launches";
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
