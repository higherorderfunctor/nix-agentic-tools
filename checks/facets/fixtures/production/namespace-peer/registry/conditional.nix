{
  facetOwner,
  facetSource,
}: {
  config,
  lib,
  nativeRegistryMarker,
  ...
}: {
  # A private import must see the merged activation and module arguments
  # while retaining the enclosing owner's provenance.
  config.facetMock.entries = lib.optionalAttrs config.facetMock.activate {
    conditional-child = {
      owner = facetOwner;
      payload = nativeRegistryMarker;
      source = toString facetSource;
    };
  };
}
