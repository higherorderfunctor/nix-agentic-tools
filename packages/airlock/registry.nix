{facetOwner, ...}: {
  documentation.aiCliDescriptions.airlock = "Local egress proxy for coding harnesses";
  fragments.categories.airlock = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "airlock";
        dir = facetOwner;
      }
    ];
  };
}
