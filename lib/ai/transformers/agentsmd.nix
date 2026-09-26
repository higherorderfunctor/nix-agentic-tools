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
  # it and links to the documents that hold its text, ONE per line. A glob or
  # a link is an unbreakable token, so no Markdown formatter re-wraps a line
  # of this shape and no reader can find a span split across two.
  renderIndexEntry = name: {
    matcher,
    references,
    ...
  }: let
    code = value: "`${value}`";
    item = value: "    - ${value}\n";
  in
    "- **${code name}**\n"
    + "  - Match:\n"
    + lib.concatMapStrings (glob: item (code glob)) matcher
    + "  - Read:\n"
    + lib.concatMapStrings (path: item "[${code path}](${path})") references;

  # Render the shared AGENTS.md target from named units: the path-scoped
  # index, then the inlined rules, each in attribute-name order, then the
  # context body. The compact, always-applicable units go FIRST because a
  # reader may stop early: Codex reads only the first `project_doc_max_bytes`
  # (32 KiB by default) and drops the rest without a word, and a raised limit
  # applies only where its project config is present and trusted. A long
  # context therefore loses its own tail, never the index or a rule. The rule
  # comments keep key provenance without introducing frontmatter or another
  # metadata schema.
  #
  # The layout is the Markdown formatter's fixed point, so a repository that
  # commits this file and formats its tree never fights the writer: one blank
  # line between units and after each rule comment, one trailing newline, and
  # an index preamble wrapped at 80 columns.
  renderKeyed = {
    context ? null,
    index ? {},
    rules ? {},
  }: let
    trimEnd = text:
      if lib.hasSuffix "\n" text
      then trimEnd (lib.removeSuffix "\n" text)
      else text;
    units =
      lib.optional (index != {}) (
        ''
          ## Path-scoped rules

          Before editing a path that matches an entry below, read every document listed
          for it. When several entries match, their guidance composes.

        ''
        + lib.concatStrings (lib.attrValues index)
      )
      ++ lib.mapAttrsToList (
        name: body: "<!-- rule: ${name} -->\n\n${body}"
      )
      rules
      ++ lib.optional (context != null && context != "") context;
  in
    lib.optionalString (units != []) (lib.concatMapStringsSep "\n\n" trimEnd units + "\n");
}
