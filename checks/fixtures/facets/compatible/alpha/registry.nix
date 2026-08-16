{
  config,
  fixtureToken,
  options,
  owner,
  source,
  ...
}: {
  config.facetMock.entries.alpha = {
    inherit owner;
    payload =
      if builtins.isAttrs config && options.facetMock ? entries
      then "alpha:${fixtureToken}:module"
      else throw "facet registry contribution did not receive native module arguments";
    source = toString source;
  };
}
