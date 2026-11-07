{facetOwner, ...}: {
  documentation.devToolDescriptions.microvm = "The microvm.nix CLI for managing declared MicroVMs";
  fragments.categories.microvm = {
    scopes = [
      "lib/ai/sharedOptions.nix"
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        location = "package";
        name = "sandbox";
        dir = facetOwner;
      }
    ];
  };
}
