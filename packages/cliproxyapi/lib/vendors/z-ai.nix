# z.ai owns static identities and credential defaults, keeping endpoints and tool repairs local.
{lib}: let
  # Read measured z.ai facts at their owner, never through the catalog core.
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  # Missing or divergent facts fail at extraction's shared reader.
  extracted = facts.get (facts.load {dir = ../../extracted;}).aggregate "zAi";
  # z.ai serves GLM models; zhipuai is the maker namespace upstream ids use (OpenCode Go canonical_id).
  catalog = {
    models = lib.genAttrs extracted.models (_: {
      aliases = {};
      maker = "zhipuai";
      source = ["cliproxyapi:zAi.models"];
    });
    vendors.z-ai.models = extracted.models;
  };
in {
  # Static contributions do not depend on the consumer's merged configuration.
  inherit catalog;
  # Both standalone callers and instances use this constructor and the selected identities.
  construct = merged:
    extracted
    // {
      codexShellArgCleanup = true;
      models = map (id: let
        aliases = merged.models.${id}.aliases.z-ai or [];
      in
        lib.findFirst (name: lib.elem name extracted.models) id ([id] ++ aliases))
      merged.vendors.z-ai.models;
      toolAliases.ToolSearch = "ToolSearch_";
    };
}
