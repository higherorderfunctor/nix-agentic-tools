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
        "evaluation-isolation"
        "integration-gate"
        "metadata-library"
        "owner-layout"
        "source-identity"
        "target-contract"
      ];
  };
}
