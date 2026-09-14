{facetOwner, ...}: {
  checks.cacheHitParity.kimchi = {consumerPath = ["ai" "kimchi"];};
  documentation.aiCliDescriptions.kimchi = "Kimchi CLI";
  # kimchi: two-tree factory (config.json + harness/), runtime SOPS
  # credential, wrapProgram separator + flattenDotKeys gotchas.
  fragments.categories.kimchi = {
    scopes = [
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        location = "package";
        name = "kimchi-factory";
        dir = facetOwner;
      }
    ];
  };
  update.targets.kimchi = {
    flags = ["--use-update-script"];
  };
}
