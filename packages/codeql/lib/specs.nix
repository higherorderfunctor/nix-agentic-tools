# `mkQueryPack` and `mkModelPack`: a CodeQL pack spec, plain data that names a
# pack and its source. No engine is read here. An engine's customizePackage
# realizes a spec against itself (./packs.nix), because a query pack compiles
# against one engine's bundled libraries. A spec takes `language` for
# codeql-full, which carries every language; a language engine supplies its
# own. Direct callers get a throw for a bad argument. See ../docs/customize.md.
{lib}: let
  type = "codeql-pack-spec";

  # Checked here for a path `src`, and in the realizing build for every other
  # kind, which eval cannot read without import-from-derivation.
  ownManifest = "`src` already holds a qlpack.yml; hand that directory to customizePackage as it is";

  errors = args: let
    unknown = builtins.attrNames (builtins.removeAttrs args ["language" "name" "src"]);
  in
    lib.optional (unknown != []) "unknown argument(s) ${lib.concatStringsSep ", " unknown}; expected name, src and language"
    ++ lib.optional (!(builtins.isString (args.name or null) && builtins.match "[a-z0-9-]+/[a-z0-9-]+" args.name != null))
    "`name` must be `<scope>/<name>` in lowercase letters, digits and hyphens"
    ++ lib.optional (!(args ? src)) "`src` is required"
    ++ lib.optional (args ? src && builtins.isPath args.src && builtins.pathExists (args.src + "/qlpack.yml")) ownManifest
    ++ lib.optional (args ? language && !builtins.isString args.language) "`language` must be a string";

  spec = kind: args: let
    problems = errors args;
  in
    assert lib.assertMsg (problems == []) "codeql.mk${lib.toSentenceCase kind}Pack:\n${lib.concatStringsSep "\n" problems}";
      {
        _type = type;
        inherit kind;
        inherit (args) name src;
      }
      // lib.optionalAttrs (args ? language) {inherit (args) language;};
in {
  inherit ownManifest;
  isSpec = lib.isType type;
  mkModelPack = spec "model";
  mkQueryPack = spec "query";
}
