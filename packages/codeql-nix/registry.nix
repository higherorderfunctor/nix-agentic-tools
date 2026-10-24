{facetOwner, ...}: {
  fragments.categories.codeql-nix = {
    scopes = ["packages/${facetOwner}/**"];
    sources =
      map (name: {
        dir = facetOwner;
        location = "package";
        inherit name;
      }) [
        "all-definitions"
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
        "renames"
        "source-identity"
        "target-contract"
      ];
  };
}
