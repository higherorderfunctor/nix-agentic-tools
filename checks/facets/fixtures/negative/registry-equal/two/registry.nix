# Two ordinary definitions must report ownership, not a native value merge error.
{
  facetOwner,
  facetSource,
  ...
}: {
  config.facetMock.entries.shared = {
    owner = facetOwner;
    payload = "two";
    source = toString facetSource;
  };
}
