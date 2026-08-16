{
  owner,
  source,
  ...
}: {
  config.facetMock.entries.charlie = {
    inherit owner;
    payload = "charlie";
    source = toString source;
  };
}
