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
        claude = {package}: fragment: let
          desc = let
            d = fragment.description or null;
          in
            if d != null && d != ""
            then d
            else "Instructions for the ${package} package";
          pathsAttr = fragment.paths or null;
          hasPaths = pathsAttr != null;
          fmStr =
            if !hasPaths
            then
              # No paths: only show frontmatter if description was explicitly set
              if (fragment.description or null) != null && fragment.description != ""
              then "---\ndescription: ${desc}\n---\n\n"
              else ""
            else if builtins.isList pathsAttr
            then
              "---\n"
              + "description: ${desc}\n"
              + "paths:\n"
              + lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") pathsAttr
              + "\n---\n\n"
            else
              mkFrontmatter {
                description = desc;
                paths = pathsAttr;
              }
              + "\n";
        in
          fmStr + fragment.text;

        # transforms.copilot {} fragment
        copilot = _: fragment: let
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
          descStr =
            if descAttr != null && descAttr != ""
            then descAttr
            else if pathsAttr == null
            then "Shared coding standards and conventions"
            else "Instructions for the ${name} package";
          fm =
            {
              inherit inclusion name;
              description = descStr;
            }
            // lib.optionalAttrs (patternStr != null) {
              fileMatchPattern = patternStr;
            };
        in
          mkFrontmatter fm
          + "\n"
          + fragment.text;

        # transforms.agentsmd {} fragment
        agentsmd = _: fragment: fragment.text;
      };
    };
}
