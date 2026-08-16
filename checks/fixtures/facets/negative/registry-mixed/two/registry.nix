{
  facetOwner,
  facetSource,
  lib,
  ...
}: {
  config.facetMock.entries.shared = lib.mkForce {
    owner = facetOwner;
    payload = "forced";
    source = toString facetSource;
  };
}
