{
  facetOwner,
  facetSource,
  ...
}: {
  config.facetMock.entries.shared = {
    owner = facetOwner;
    payload = "ordinary";
    source = toString facetSource;
  };
}
