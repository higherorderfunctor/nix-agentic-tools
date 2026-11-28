# The second owner reads the first owner's activation; isolated settings would hide its claim.
{
  config,
  facetOwner,
  facetSource,
  lib,
  ...
}: {
  config.facetMock.entries = lib.optionalAttrs config.facetMock.activate {
    shared = lib.mkForce {
      owner = facetOwner;
      payload = "two";
      source = toString facetSource;
    };
  };
}
