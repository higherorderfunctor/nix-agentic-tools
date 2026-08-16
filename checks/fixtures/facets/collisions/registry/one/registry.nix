{
  owner,
  source,
  ...
}: {
  config.facetMock.entries.shared = {
    inherit owner;
    payload = "one";
    source = toString source;
  };
}
