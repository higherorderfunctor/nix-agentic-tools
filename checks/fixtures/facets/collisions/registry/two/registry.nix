{
  owner,
  source,
  ...
}: {
  config.facetMock.entries.shared = {
    inherit owner;
    payload = "two";
    source = toString source;
  };
}
