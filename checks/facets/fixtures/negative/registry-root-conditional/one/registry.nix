# Root attribution must see the competing claim activated by this owner.
{
  facetOwner,
  facetSource,
  ...
}: {
  config.facetMock = {
    activate = true;
    entries.conditional-root = {
      owner = facetOwner;
      payload = "one";
      source = toString facetSource;
    };
  };
}
