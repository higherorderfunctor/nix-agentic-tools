{
  facetOwner,
  facetSource,
  lib,
  ...
}: {
  config.facetMock.entries.root-policy = lib.mkForce {
    owner = facetOwner;
    payload = "owner-override";
    source = toString facetSource;
  };
}
