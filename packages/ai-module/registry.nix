{facetOwner, ...}: {
  fragments.categories.ai-module-architecture = {
    scopes = [
      "checks/service-instances/**"
      "checks/service-secret-ordering/**"
      "lib/ai/app/generatedFiles.nix"
      "lib/ai/sharedOptions.nix"
      "lib/redact/default.nix"
      "packages/*/modules/instances.nix"
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "architecture";
      }
    ];
  };
}
