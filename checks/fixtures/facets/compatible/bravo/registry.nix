{
  owner,
  source,
  ...
}: {
  config.facetMock.entries.bravo = {
    inherit owner;
    payload = "bravo";
    source = toString source;
  };
}
