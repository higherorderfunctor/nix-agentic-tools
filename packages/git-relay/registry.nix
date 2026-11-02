{facetOwner, ...}: {
  documentation.genericDescriptions.git-relay = "Git relay daemon: forwards pushes to an upstream with a key the pusher never holds";
  fragments.categories.git-relay = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "git-relay";
      }
    ];
  };
}
