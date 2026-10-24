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
        "implicit-scope"
        "installed-extractor"
        "integration-gate"
        "lexical-scope"
        "literal-imports"
        "metadata-library"
        "module-adapter"
        "module-graph"
        "module-properties"
        "owner-layout"
        "source-identity"
        "target-contract"
      ];
  };
}
