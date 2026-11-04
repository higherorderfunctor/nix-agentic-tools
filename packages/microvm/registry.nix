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
      {
        location = "package";
        name = "sandbox-git";
        dir = facetOwner;
      }
      {
        location = "package";
        name = "sandbox-identities";
        dir = facetOwner;
      }
      {
        location = "package";
        name = "sandbox-signing";
        dir = facetOwner;
      }
    ];
  };
}
