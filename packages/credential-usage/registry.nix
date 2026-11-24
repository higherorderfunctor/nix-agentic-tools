# The fragment registry uses the owner directory to find the credential-usage
# guidance and scope it to files in that package.
{facetOwner, ...}: {
  fragments.categories.credential-usage = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "credential-usage";
      }
    ];
  };
}
