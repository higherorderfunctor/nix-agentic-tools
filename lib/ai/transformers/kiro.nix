# Kiro transformer — YAML frontmatter with inclusion/fileMatchPattern.
#
# Behavior preserved from packages/fragments-ai/default.nix transforms.kiro:
# - paths: null → inclusion = "always", omit fileMatchPattern
# - paths: list of 1 → inclusion = "fileMatch", fileMatchPattern = "<one>"
# - paths: list of >1 → inclusion = "fileMatch", fileMatchPattern = [...]
#     (inline YAML array — comma-joined strings are wrong per kiro.dev/docs)
# - paths: string → inclusion = "fileMatch", fileMatchPattern = raw string
# - description: non-empty → always include
# - description: "" → always omit
# - description: null + paths set + name supplied → default to
#     "Instructions for the ${name} package"
# - `name` is an optional ctxExtra; when supplied, included as the
#   `name:` field in frontmatter (matches kiro.dev steering schema).
{lib}: let
  fragments = import ../../fragments.nix {inherit lib;};
in rec {
  kiroTransformer = {
    name = "kiro";
    handlers =
      fragments.defaultHandlers
      // {
        link = _ctx: node: "[${node.label or node.target}](${node.target})";
        include = _ctx: node: "#[[file:${node.path}]]";
      };
    frontmatter = {
      description ? null,
      paths ? null,
      name ? null,
      ...
    }: let
      inclusion =
        if paths != null
        then "fileMatch"
        else "always";
      patternStr =
        if paths == null
        then null
        else if builtins.isList paths
        then
          if builtins.length paths == 1
          then ''"${builtins.head paths}"''
          else "[" + lib.concatMapStringsSep ", " (p: ''"${p}"'') paths + "]"
        else paths;
      descStr =
        if description != null && description != ""
        then description
        else if description == null && paths != null && name != null
        then "Instructions for the ${name} package"
        else null;
      fm =
        {inherit inclusion;}
        // lib.optionalAttrs (name != null) {inherit name;}
        // lib.optionalAttrs (descStr != null) {description = descStr;}
        // lib.optionalAttrs (patternStr != null) {fileMatchPattern = patternStr;};
    in
      fragments.mkFrontmatter fm + "\n";
    assemble = {
      frontmatter,
      body,
    }:
      frontmatter + body;
  };

  render = fragments.mkRenderer kiroTransformer {};
}
