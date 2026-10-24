{facetOwner, ...}: {
  documentation.genericDescriptions.airlock = "Credential-injecting egress gateway for coding harnesses";
  fragments.categories.airlock = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "airlock";
      }
    ];
  };
}
