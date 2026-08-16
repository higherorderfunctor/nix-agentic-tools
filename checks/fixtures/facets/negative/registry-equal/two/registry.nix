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
