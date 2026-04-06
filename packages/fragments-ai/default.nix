# AI ecosystem transforms — curried frontmatter generators.
# Derivation: pkgs.fragments-ai
# passthru.transforms provides eval-time access to transform factories.
_: final: _prev: let
  fragmentsLib = import ../../lib/fragments.nix {inherit (final) lib;};
  inherit (fragmentsLib) mkFrontmatter;
  inherit (final) lib;
in {
  fragments-ai =
    final.runCommand "fragments-ai" {} ''
      mkdir -p $out/templates
      cp ${./templates}/*.md $out/templates/
    ''
    // {
      passthru.transforms = {
        # transforms.claude { package = "my-app"; } fragment
        #
        # Handles three path formats:
        # - null: no paths frontmatter
        # - list: YAML list (from instructionModule)
        # - string: pre-quoted glob (from packagePaths in generate/devenv)
        #
        # Description logic:
        # - null (from compose): omit when no paths, default when paths set
        # - "" (from instructionModule default): always omit
        # - non-empty string: always include
        claude = {package}: fragment: let
          descAttr = fragment.description or null;
          pathsAttr = fragment.paths or null;
          hasPaths = pathsAttr != null;
          # Resolve description: non-empty explicit > default-for-paths > omit
          desc =
            if descAttr != null && descAttr != ""
            then descAttr
            else if hasPaths && descAttr == null
            then "Instructions for the ${package} package"
            else null;
          descYaml =
            if desc != null
            then "description: ${desc}\n"
            else "";
          pathsYaml =
            if pathsAttr == null
            then ""
            else if builtins.isList pathsAttr
            then "paths:\n" + lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") pathsAttr + "\n"
            else "paths: ${pathsAttr}\n";
          fmStr =
            if descYaml == "" && pathsYaml == ""
            then ""
            else "---\n" + descYaml + pathsYaml + "---\n\n";
        in
          fmStr + fragment.text;

        # transforms.copilot fragment
        copilot = fragment: let
          pathsAttr = fragment.paths or null;
          applyTo =
            if pathsAttr == null
            then ''"**"''
            else if builtins.isList pathsAttr
            then ''"${lib.concatStringsSep "," pathsAttr}"''
            else pathsAttr;
        in
          mkFrontmatter {inherit applyTo;}
          + "\n"
          + fragment.text;

        # transforms.kiro { name = "my-rule"; } fragment
        #
        # Description logic:
        # - non-empty string: always include
        # - "" (from instructionModule default): omit
        # - null (from compose or ecosystem generate): use contextual default
        kiro = {name}: fragment: let
          pathsAttr = fragment.paths or null;
          descAttr = fragment.description or null;
          inclusion =
            if pathsAttr != null
            then "fileMatch"
            else "always";
          patternStr =
            if pathsAttr == null
            then null
            else if builtins.isList pathsAttr
            then ''"${lib.concatStringsSep "," pathsAttr}"''
            else pathsAttr;
          # Resolve description: non-empty explicit > null-default > omit for ""
          descStr =
            if descAttr != null && descAttr != ""
            then descAttr
            else if descAttr == null
            then
              if pathsAttr == null
              then "Shared coding standards and conventions"
              else "Instructions for the ${name} package"
            else null;
          fm =
            {
              inherit inclusion name;
            }
            // lib.optionalAttrs (descStr != null) {
              description = descStr;
            }
            // lib.optionalAttrs (patternStr != null) {
              fileMatchPattern = patternStr;
            };
        in
          mkFrontmatter fm
          + "\n"
          + fragment.text;

        # transforms.agentsmd fragment
        agentsmd = fragment: fragment.text;
      };
    };
}
