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

  # One extra manual index level, only when it reduces the root index's bytes.
  # Plain relative file links can be rebased by directory depth; URLs, anchors,
  # query strings and Markdown-escaped paths stay in the root unchanged.
  tierIndex = {
    filename,
    audiences,
    hasOnDemandIndex,
    index,
  }: let
    isRelativeFile = ref: builtins.match "([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+" ref != null;
    rootPrefix = lib.concatStrings (lib.replicate (builtins.length (lib.splitString "/" filename) - 1) "../");
    rootIndex = lib.mapAttrs (_: entry:
      entry
      // {
        references = map (ref:
          if isRelativeFile ref
          then rootPrefix + ref
          else ref)
        entry.references;
      })
    index;
    eligible = lib.filterAttrs (_: entry:
      entry.inclusion
      == "fileMatch"
      && entry.references != []
      && lib.all isRelativeFile entry.references
      && builtins.length (lib.unique (map builtins.dirOf entry.references)) == 1)
    index;
    candidates = lib.groupBy (name: builtins.dirOf (builtins.head eligible.${name}.references)) (lib.attrNames eligible);
    # Prefer the document group (packages/kimchi/docs -> kimchi). Preserve the
    # full directory hierarchy when two parents have the same readable name.
    # Reversible underscore tokens keep links URL-safe. Escaping dots also
    # prevents a directory component from colliding with an
    # index.md file, and keeps literal . and .. components inside this tree.
    pathComponent = lib.replaceStrings ["_" "%" "."] ["__" "_percent_" "_dot_"];
    pathHierarchy = path: lib.concatMapStringsSep "/" pathComponent (lib.splitString "/" path);
    preferredName = parent:
      pathComponent (builtins.baseNameOf (
        if builtins.baseNameOf parent == "docs" && builtins.dirOf parent != "."
        then builtins.dirOf parent
        else parent
      ));
    preferredGroups = lib.groupBy preferredName (lib.attrNames candidates);
    childDirectory =
      ".agents/rules/"
      + lib.optionalString (builtins.baseNameOf filename != "AGENTS.md") "targets/${pathComponent (builtins.baseNameOf filename)}/";
    # Only a literal directory followed by /** proves coverage by prefix.
    # Wildcard-bearing directory prefixes are not a glob-subsumption proof.
    rootMatchers = names: let
      matchers = lib.sort builtins.lessThan (lib.unique (lib.concatMap (name: index.${name}.matcher) names));
      broad = lib.filter (glob: lib.hasSuffix "/**" glob && builtins.match "[A-Za-z0-9._/-]+" (lib.removeSuffix "/**" glob) != null) matchers;
    in
      lib.filter (glob: !(lib.any (cover: cover != glob && lib.hasPrefix (lib.removeSuffix "**" cover) glob) broad)) matchers;
    renderIndex = state:
      renderKeyed {
        inherit audiences hasOnDemandIndex;
        inherit (state) index indexGroups;
      };
    grouped =
      lib.foldl' (state: parent: let
        names = candidates.${parent};
        entries = lib.getAttrs names index;
        groupName = preferredName parent;
        groupPath =
          if builtins.length preferredGroups.${groupName} == 1
          then "${groupName}.md"
          else "by-path/${pathHierarchy parent}/index.md";
        childName = childDirectory + groupPath;
        childPath = lib.optionalString (builtins.dirOf filename != ".") "${builtins.dirOf filename}/" + childName;
        childRootPrefix = lib.concatStrings (lib.replicate (builtins.length (lib.splitString "/" childPath) - 1) "../");
        group = {
          name = parent;
          audiences = lib.sort builtins.lessThan (lib.unique (lib.concatMap (name: audiences.${name} or []) names));
          entry = {
            description = "";
            inclusion = "fileMatch";
            matcher = rootMatchers names;
            references = [childName];
          };
        };
        next = {
          index = removeAttrs state.index names;
          indexGroups = state.indexGroups ++ [group];
          children =
            state.children
            // {
              ${childPath} =
                "Match globs use the same workspace-relative paths as the parent index. Document links below are relative to this file.\n\n"
                + renderKeyed {
                  audiences = builtins.intersectAttrs entries audiences;
                  index = lib.mapAttrs (_: entry: entry // {references = map (ref: "${childRootPrefix}${ref}") entry.references;}) entries;
                };
            };
        };
      in
        if builtins.length names >= 2 && builtins.stringLength (renderIndex next) < builtins.stringLength (renderIndex state)
        then next
        else state)
      {
        index = rootIndex;
        indexGroups = [];
        children = {};
      }
      (lib.attrNames candidates);
  in
    grouped;

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
    indexGroups ? [],
    rules ? {},
  }: let
    audienceNames = names: lib.concatMapStringsSep ", " (runtime: "`${runtime}`") names;
    entries = lib.sort (a: b: a.name < b.name) (
      lib.mapAttrsToList (name: entry: {
        inherit entry name;
        audiences = audiences.${name} or [];
      })
      index
      ++ indexGroups
    );
    indexAudiences = lib.unique (map (entry: entry.audiences) entries);
    uniformAudience = builtins.length indexAudiences == 1 && builtins.head indexAudiences != [];
    units =
      lib.optional (entries != []) (
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
        + lib.concatMapStrings (entry:
          renderIndexEntry entry.name entry.entry
          + lib.optionalString (!uniformAudience && entry.audiences != []) "  - Audience: ${audienceNames entry.audiences}\n")
        entries
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
