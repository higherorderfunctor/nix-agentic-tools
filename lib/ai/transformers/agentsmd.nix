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

  # One entry of the path-scoped index: the rule's key, the globs that select
  # it and links to the documents that hold its text. Globs and links are
  # code spans on ONE line, so no formatter or reader can split a span.
  renderIndexEntry = name: {
    matcher,
    references,
    ...
  }: let
    code = value: "`${value}`";
  in
    "- **${code name}**\n"
    + "  - Match: ${lib.concatMapStringsSep ", " code matcher}\n"
    + "  - Read: ${lib.concatMapStringsSep ", " (path: "[${code path}](${path})") references}";

  # Render the shared AGENTS.md target from named units: the context body,
  # then the path-scoped index, then the inlined rules, each group in
  # attribute-name order. The index follows the context directly because it
  # is what points a reader at everything the file does not inline. The rule
  # comments keep key provenance without introducing frontmatter or another
  # metadata schema.
  renderKeyed = {
    context ? null,
    index ? {},
    rules ? {},
  }:
    lib.concatStringsSep "\n\n" (
      lib.optional (context != null && context != "") context
      ++ lib.optional (index != {}) (
        ''
          ## Path-scoped rules

          Before editing a path that matches an entry below, read every document listed for it. When several entries match, their guidance composes.

        ''
        + lib.concatMapStrings (entry: entry + "\n") (lib.attrValues index)
      )
      ++ lib.mapAttrsToList (
        name: body: "<!-- rule: ${name} -->\n${body}"
      )
      rules
    );
}
