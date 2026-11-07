{facetOwner, ...}: {
  fragments.categories.jail-nix = {
    scopes = ["checks/ai-jail/**" "lib/ai/app/mkBackendTransform.nix" "lib/ai/jail/**" "packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "jail-nix";
      }
    ];
  };
}
