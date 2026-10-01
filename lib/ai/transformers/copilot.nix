# Copilot transformer — YAML frontmatter with `applyTo` glob.
#
# Behavior preserved from packages/fragments-ai/default.nix transforms.copilot:
# - paths: null   → applyTo = "**" (always-loaded)
# - paths: list   → applyTo = comma-joined glob string
# - paths: string → applyTo = raw string data
# - description is retained in the normalized record but intentionally omitted
#   from Copilot frontmatter to preserve the existing devenv output bytes.
{lib}: let
  fragments = import ../../fragments.nix {inherit lib;};
in rec {
  copilotTransformer = {
    name = "copilot";
    handlers =
      fragments.defaultHandlers
      // {
        link = _ctx: node: "[${node.label or node.target}](${node.target})";
        include = _ctx: node: throw "Copilot transformer: include nodes not supported (path=${node.path}); inline the fragment instead";
      };
    frontmatterData = {paths ? null, ...}: let
      applyTo =
        if paths == null
        then "**"
        else if builtins.isList paths
        then lib.concatStringsSep "," paths
        else paths;
    in {inherit applyTo;};
  };

  render = fragments.mkRenderer copilotTransformer {};
}
