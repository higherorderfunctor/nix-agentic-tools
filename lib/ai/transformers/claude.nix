# Claude transformer — YAML frontmatter with description + paths.
#
# Behavior preserved from packages/fragments-ai/default.nix transforms.claude:
# - paths: null     → omit `paths:` line
# - paths: list     → emit YAML list (one per line, two-space indent)
# - paths: string   → emit `paths: <string>` (pre-quoted glob)
# - description: null + paths set + package supplied → default to
#     "Instructions for the ${package} package"
# - description: ""     → always omit
# - description: non-empty → always include
# - both empty → no frontmatter at all (not even `---` markers)
{lib}: let
  fragments = import ../../fragments.nix {inherit lib;};
in rec {
  claudeTransformer = {
    name = "claude";
    handlers =
      fragments.defaultHandlers
      // {
        link = _ctx: node: "[${node.label or node.target}](${node.target})";
        include = _ctx: node: "@${node.path}";
      };
    frontmatter = {
      description ? null,
      paths ? null,
      package ? null,
      ...
    }: let
      hasPaths = paths != null;
      desc =
        if description != null && description != ""
        then description
        else if hasPaths && description == null && package != null
        then "Instructions for the ${package} package"
        else null;
      fm =
        lib.optionalAttrs (desc != null) {description = desc;}
        // lib.optionalAttrs hasPaths {inherit paths;};
    in
      if fm == {}
      then ""
      else fragments.mkFrontmatter fm + "\n";
    assemble = {
      frontmatter,
      body,
    }:
      frontmatter + body;
  };

  render = fragments.mkRenderer claudeTransformer {};
}
