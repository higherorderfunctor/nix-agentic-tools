# Z.ai owns static identities and credential defaults, keeping endpoints and tool repairs local.
{lib}: let
  # Read measured Z.ai facts at their owner, never through the catalog core.
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  # Missing or divergent facts fail at extraction's shared reader.
  extracted = facts.get (facts.load {dir = ../../extracted;}).aggregate "zhipuai";
  # Z.ai serves GLM models; zhipuai is the maker namespace upstream ids use (OpenCode Go canonical_id).
  catalog = {
    models = lib.genAttrs extracted.models (_: {
      maker = "zhipuai";
      source = ["cliproxyapi:zhipuai.models"];
    });
    vendors.zhipuai.models = extracted.models;
  };
in {
  # Static contributions do not depend on the consumer's merged configuration.
  inherit catalog;
  # Owner default spellings; consumers extend ai.cliproxyapi.servedModels.zhipuai.
  servedModels = lib.genAttrs extracted.models (id: [id]);
  # Both standalone callers and instances use this constructor and the selected identities.
  construct = servedModels: merged:
    extracted
    // {
      codexShellArgCleanup = true;
      models = map (id: let
        spellings = servedModels.${id} or [];
        upstream = lib.findFirst (name: lib.elem name extracted.models) null spellings;
      in
        if upstream == null
        then throw "cliproxyapi zhipuai: catalog model `${id}` has unknown served ids ${builtins.toJSON spellings}; no extracted transport metadata."
        else upstream)
      merged.vendors.zhipuai.models;
      toolAliases.ToolSearch = "ToolSearch_";
    };
}
