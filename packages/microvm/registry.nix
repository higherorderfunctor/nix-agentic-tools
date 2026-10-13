{facetOwner, ...}: {
  documentation.devToolDescriptions.microvm = "The microvm.nix CLI for managing declared MicroVMs";
  fragments.categories.microvm = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "sandbox";
        dir = facetOwner;
      }
    ];
  };
}
