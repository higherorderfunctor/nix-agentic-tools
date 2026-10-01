# Kiro transformer — YAML frontmatter with inclusion/fileMatchPattern.
#
# Default behavior preserved from packages/fragments-ai/default.nix
# transforms.kiro; an explicit `inclusion` overrides only this derivation:
# - inclusion: null + paths: null → inclusion = "always"
# - inclusion: null + paths set → inclusion = "fileMatch"
# - inclusion: "always" | "auto" | "manual" → omit fileMatchPattern
# - inclusion: "fileMatch" → emit fileMatchPattern (the shared resolver
#     requires paths before this transformer runs)
# - paths: list of 1 → fileMatchPattern is the one raw string
# - paths: list of >1 → fileMatchPattern as a YAML block sequence
#     (`- "<glob>"` per line). Kiro needs a YAML list, not a comma-joined
#     string (kiro.dev/docs), and the block form is the one list shape a
#     Markdown formatter leaves alone: prettier rewrites a long inline array
#     into a multi-line flow array, which Kiro silently loads every turn.
# - paths: string → inclusion = "fileMatch", fileMatchPattern = raw string
# - description: non-empty → always include
# - description: "" → always omit
# - description: null + paths set + name supplied → default to
#     "Instructions for the ${name} package"
# - `auto` description validation lives in the shared rule resolver
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
    frontmatterData = {
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
        else if requestedInclusion == "fileMatch" && paths == null
        then throw ''Kiro transformer: inclusion = "fileMatch" requires paths''
        else requestedInclusion;
      pattern =
        if effectiveInclusion != "fileMatch"
        then null
        else if builtins.isList paths && builtins.length paths == 1
        then builtins.head paths
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
        // lib.optionalAttrs (pattern != null) {fileMatchPattern = pattern;};
    in
      fm;
  };

  render = fragments.mkRenderer kiroTransformer {};
}
