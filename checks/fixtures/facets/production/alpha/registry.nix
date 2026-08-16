{
  facetOwner,
  facetSource,
  ...
}: {
  config.facetMock.entries.alpha = {
    owner = facetOwner;
    payload = "alpha";
    source = toString facetSource;
  };
}
