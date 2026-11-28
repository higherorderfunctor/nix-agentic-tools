# An unconditional owner override must not supersede the root-owned policy entry.
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
