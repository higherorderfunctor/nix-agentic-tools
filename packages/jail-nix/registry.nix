{facetOwner, ...}: {
  fragments.categories.jail-nix = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "jail-nix";
      }
    ];
  };
}
