{facetOwner, ...}: {
  fragments.categories.codeql-nix = {
    scopes = ["packages/${facetOwner}/**"];
    sources =
      map (name: {
        dir = facetOwner;
        location = "package";
        inherit name;
      }) [
        "database-contract"
        "integration-gate"
        "owner-layout"
        "target-contract"
      ];
  };
}
