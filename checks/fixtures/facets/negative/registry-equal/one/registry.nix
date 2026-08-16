{
  facetOwner,
  facetSource,
  ...
}: {
  config.facetMock.entries.shared = {
    owner = facetOwner;
    payload = "one";
    source = toString facetSource;
  };
}
