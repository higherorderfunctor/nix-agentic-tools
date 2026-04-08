# Copilot transformer — YAML frontmatter with `applyTo` glob.
#
# Behavior preserved from packages/fragments-ai/default.nix transforms.copilot:
# - paths: null   → applyTo = "**" (always-loaded)
# - paths: list   → applyTo = comma-joined glob string
# - paths: string → applyTo = raw string (pre-quoted)
# - description is intentionally ignored — Copilot frontmatter is just applyTo.
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
    frontmatter = {paths ? null, ...}: let
      applyTo =
        if paths == null
        then ''"**"''
        else if builtins.isList paths
        then ''"${lib.concatStringsSep "," paths}"''
        else paths;
    in
      fragments.mkFrontmatter {inherit applyTo;} + "\n";
    assemble = {
      frontmatter,
      body,
    }:
      frontmatter + body;
  };

  render = fragments.mkRenderer copilotTransformer {};
}
