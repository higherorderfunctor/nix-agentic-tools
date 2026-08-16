{
  owner,
  source,
  ...
}: {
  config.facetMock.entries.alpha = {
    inherit owner;
    payload = "alpha";
    source = toString source;
  };
}
