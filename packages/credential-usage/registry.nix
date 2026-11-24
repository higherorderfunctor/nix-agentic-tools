{facetOwner, ...}: {
  fragments.categories.credential-usage = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "credential-usage";
      }
    ];
  };
}
