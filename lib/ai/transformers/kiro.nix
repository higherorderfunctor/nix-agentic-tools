# Kiro transformer — YAML frontmatter with inclusion/fileMatchPattern.
#
# Default behavior preserved from packages/fragments-ai/default.nix
# transforms.kiro; an explicit `inclusion` overrides only this derivation:
# - inclusion: null + paths: null → inclusion = "always"
# - inclusion: null + paths set → inclusion = "fileMatch"
# - inclusion: "always" | "auto" | "manual" → omit fileMatchPattern
# - inclusion: "fileMatch" → require paths and emit fileMatchPattern
# - paths: list of 1 → fileMatchPattern = "<one>"
# - paths: list of >1 → fileMatchPattern = [...]
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
      inclusion ? null,
      name ? null,
      paths ? null,
      ...
    }: let
      requestedInclusion =
        if inclusion != null
        then inclusion
        else if paths != null
        then "fileMatch"
        else "always";
      effectiveInclusion =
        if !(builtins.elem requestedInclusion ["always" "auto" "fileMatch" "manual"])
        then throw "Kiro transformer: invalid inclusion mode '${requestedInclusion}'"
        else if requestedInclusion == "auto" && (name == null || name == "")
        then throw ''Kiro transformer: inclusion = "auto" requires a non-empty name''
        else if requestedInclusion == "auto" && (description == null || description == "")
        then throw ''Kiro transformer: inclusion = "auto" requires a non-empty description''
        else if requestedInclusion == "fileMatch" && paths == null
        then throw ''Kiro transformer: inclusion = "fileMatch" requires paths''
        else requestedInclusion;
      patternStr =
        if effectiveInclusion != "fileMatch"
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
        else if description == null && effectiveInclusion == "fileMatch" && name != null
        then "Instructions for the ${name} package"
        else null;
      fm =
        {inclusion = effectiveInclusion;}
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
