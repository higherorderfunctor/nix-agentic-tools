# AGENTS.md transformer — flat body, no frontmatter.
#
# Behavior preserved from packages/fragments-ai/default.nix transforms.agentsmd:
# `agentsmd = fragment: fragment.text;` — passes through the text only,
# discarding any description / paths frontmatter metadata. Codex and other
# generic agents.md consumers don't read frontmatter.
{lib}: let
  fragments = import ../../fragments.nix {inherit lib;};
in rec {
  agentsmdTransformer = {
    name = "agentsmd";
    handlers =
      fragments.defaultHandlers
      // {
        link = _ctx: node: "[${node.label or node.target}](${node.target})";
        include = _ctx: node: node.path;
      };
    frontmatter = _: "";
    assemble = {
      frontmatter,
      body,
    }:
      frontmatter + body;
  };

  render = fragments.mkRenderer agentsmdTransformer {};

  # Render the shared AGENTS.md target from named units. The context body is
  # always first; rules follow in attribute-name order. The rule comments keep
  # key provenance without introducing frontmatter or another metadata schema.
  renderKeyed = {
    context ? null,
    rules ? {},
  }:
    lib.concatStringsSep "\n\n" (
      lib.optional (context != null && context != "") context
      ++ lib.mapAttrsToList (
        name: body: "<!-- rule: ${name} -->\n${body}"
      )
      rules
    );
}
