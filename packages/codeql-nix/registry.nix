{facetOwner, ...}: {
  fragments.categories.codeql-nix = {
    scopes = ["packages/${facetOwner}/**"];
    sources =
      map (name: {
        dir = facetOwner;
        location = "package";
        inherit name;
      }) [
        "builtin-models"
        "database-contract"
        "evaluation-isolation"
        "installed-extractor"
        "integration-gate"
        "metadata-library"
        "module-adapter"
        "owner-layout"
        "source-identity"
        "target-contract"
      ];
  };
}
