# Base markdown transformer record.
#
# Other transformers extend this via lib.recursiveUpdate. The base
# provides default handlers for raw and block (recursive walk via
# ctx.render), an empty frontmatter, and a frontmatter+body
# assemble. Per-target transformers override link, include,
# frontmatter, and (rarely) assemble.
#
# See dev/notes/ai-transformer-design.md Layer 2.5 for the design.
{lib}: let
  fragments = import ../fragments.nix {inherit lib;};
  inherit (fragments) defaultHandlers;
in {
  name = "base";
  handlers = defaultHandlers;
  frontmatter = _: "";
  assemble = {
    frontmatter,
    body,
  }:
    frontmatter + body;
}
