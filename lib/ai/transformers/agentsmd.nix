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
    frontmatterData = _: {};
  };

  render = fragments.mkRenderer agentsmdTransformer {};

  renderScope = inclusion: matcher:
    lib.optionalString (inclusion == "fileMatch") (
      "_Apply this guidance only when working with files matching: "
      + lib.concatMapStringsSep ", " (path: "`${path}`") matcher
      + "_\n\n"
    );

  mkRuleBody = readContent: _name: rule:
    renderScope rule.inclusion rule.matcher
    + render {
      text = readContent rule;
    };

  # AGENTS.md has no native trigger metadata. fileMatch rules with references
  # use the compact path index; auto/manual rules require references and use
  # the same index as their on-demand pointer. Everything else is inlined.
  isIndexedRule = rule:
    builtins.elem rule.inclusion ["auto" "manual"]
    || (rule.inclusion == "fileMatch" && rule.references != []);

  agentsMdUnits = {
    readContent,
    resolveInclusion,
    rules,
    runtime,
  }: let
    routedRules = lib.mapAttrs (name: rule:
      rule
      // {
        inclusion = resolveInclusion {
          inherit name rule runtime;
        };
      })
    rules;
    indexedRules = lib.filterAttrs (_name: isIndexedRule) routedRules;
  in {
    hasOnDemandIndex = lib.any (
      rule: builtins.elem rule.inclusion ["auto" "manual"]
    ) (lib.attrValues indexedRules);
    # Keep trigger data until the shared composer renders the final index.
    index =
      lib.mapAttrs (_name: rule: {
        inherit (rule) description inclusion matcher references;
      })
      indexedRules;
    rules = lib.mapAttrs (mkRuleBody readContent) (lib.filterAttrs (_name: rule: !(isIndexedRule rule)) routedRules);
  };

  # One entry of the path-scoped index: the rule's key, the globs that select
  # it and links to the documents that hold its text, ONE per line. A glob or
  # a link is an unbreakable token, so no Markdown formatter re-wraps a line
  # of this shape and no reader can find a span split across two.
  renderIndexEntry = name: {
    description ? "",
    inclusion ? "fileMatch",
    matcher,
    references,
    ...
  }: let
    code = value: "`${value}`";
    item = value: "    - ${value}\n";
  in
    "- **${code name}**\n"
    + (
      if inclusion == "fileMatch"
      then
        "  - Match:\n"
        + lib.concatMapStrings (glob: item (code glob)) matcher
      else
        "  - Trigger: `${inclusion}`\n"
        + lib.optionalString (description != "") "  - Description: ${description}\n"
    )
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
  renderKeyed = {
    audiences ? {},
    context ? null,
    hasOnDemandIndex ? false,
    index ? {},
    rules ? {},
  }: let
    audienceNames = names: lib.concatMapStringsSep ", " (runtime: "`${runtime}`") names;
    indexAudiences = lib.unique (map (name: audiences.${name} or []) (lib.attrNames index));
    uniformAudience = builtins.length indexAudiences == 1 && builtins.head indexAudiences != [];
    units =
      lib.optional (index != {}) (
        (
          if hasOnDemandIndex
          then ''
            ## Rule index

            Read the documents listed for a rule when its trigger applies. Path matches
            and model-selected triggers may compose, so read every applicable entry.

          ''
          else ''
            ## Path-scoped rules

            Before editing a path that matches an entry below, read every document listed
            for it. When several entries match, their guidance composes.

          ''
        )
        + lib.optionalString (audiences != {}) (
          (
            if uniformAudience
            then "This fallback index applies only to: ${audienceNames (builtins.head indexAudiences)}.\n"
            else "This fallback index applies only to the runtimes named in each entry.\n"
          )
          + ''
            Runtimes with native rule injection already receive their applicable
            rules; do not follow this fallback index to load additional guidance.
          ''
          + (
            if uniformAudience
            then "If your runtime is not named, skip this index.\n\n"
            else "If your runtime is not named, skip the entry.\n\n"
          )
        )
        + lib.concatStrings (lib.mapAttrsToList (name: entry:
          renderIndexEntry name entry
          + lib.optionalString (!uniformAudience && audiences ? ${name}) "  - Audience: ${audienceNames audiences.${name}}\n")
        index)
      )
      ++ lib.mapAttrsToList (
        name: body:
          "<!-- rule: ${name} -->\n\n"
          + lib.optionalString (audiences ? ${name}) "Apply this rule only in: ${audienceNames audiences.${name}}.\n\n"
          + body
      )
      rules
      ++ lib.optional (context != null && context != "") context;
  in
    lib.optionalString (units != []) (lib.concatStringsSep "\n\n" units);
}
