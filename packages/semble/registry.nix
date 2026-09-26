{facetOwner, ...}: {
  checks.cacheHitParity = {
    semble = {consumerPath = ["ai" "semble"];};
    semble-mcp = {consumerPath = ["ai" "mcpServers" "semble-mcp"];};
  };
  documentation = {
    aiCliDescriptions.semble = "Local semantic and lexical code-search CLI";
    mcpServerMeta.semble-mcp = {
      description = "Local semantic and lexical code search";
      credentials = "None";
    };
  };
  # Program-factory integration, customization, cache ownership, and the
  # shared HM/devenv backend contract. Not keyed `semble`: the category is a
  # root `ai.rules` entry in this repository, and the Semble program's own
  # per-runtime `rules.semble` (its CLI rule, public API) would replace it at
  # the same key.
  fragments.categories.semble-integration = {
    scopes = ["packages/${facetOwner}/**"];
    sources = [
      {
        location = "package";
        name = "semble";
        dir = facetOwner;
      }
    ];
  };
}
