{
  facetOwner,
  facetSource,
  inputs,
  lib,
  ...
}: {
  imports = [
    {
      config.facetMock.entries.git-revise.payload = lib.mkDefault "same-owner-default";
    }
  ];

  config.facetMock.entries.git-revise = {
    owner = facetOwner;
    payload = inputs.fixture.sentinel;
    source = toString facetSource;
  };
}
