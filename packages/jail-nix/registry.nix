{facetOwner, ...}: {
  fragments.categories.jail-nix = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "jail-nix";
        dir = facetOwner;
      }
    ];
  };
}
