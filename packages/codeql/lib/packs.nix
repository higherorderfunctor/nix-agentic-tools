# `mkQueryPack` and `mkModelPack` on one engine: a CodeQL pack from a source
# directory, with a qlpack.yml both builders render from the same function. A
# query pack is precompiled with `codeql pack create`, offline, against the
# engine's bundled `codeql/<language>-all`. Direct callers get a throw for a
# bad argument. See ../docs/codeql.md.
{
  engine,
  engineName,
  languages,
  pkgs,
}: let
  inherit (pkgs) lib;

  # The language a language bundle carries; the full bundle needs it named.
  defaultLanguage =
    if lib.elem engineName languages
    then engineName
    else null;

  errors = args: let
    unknown = builtins.attrNames (builtins.removeAttrs args ["language" "name" "src"]);
    language = args.language or defaultLanguage;
  in
    lib.optional (unknown != []) "unknown argument(s) ${lib.concatStringsSep ", " unknown}; expected name, src and language"
    ++ lib.optional (!(builtins.isString (args.name or null) && builtins.match "[a-z0-9-]+/[a-z0-9-]+" args.name != null))
    "`name` must be `<scope>/<name>` in lowercase letters, digits and hyphens"
    ++ lib.optional (!(args ? src)) "`src` is required"
    ++ lib.optional (args ? src && builtins.isPath args.src && builtins.pathExists (args.src + "/qlpack.yml"))
    "`src` already holds a qlpack.yml; hand that directory to customizePackage as it is"
    ++ lib.optional (engineName == "bare") "codeql-bare carries no CodeQL libraries; build packs with a language engine or codeql-full"
    ++ lib.optional (engineName != "bare" && !(lib.elem language languages))
    "`language` must be one of ${lib.concatStringsSep ", " languages}${lib.optionalString (defaultLanguage == null) " (codeql-${engineName} has no default)"}";

  # The one qlpack.yml renderer. JSON is YAML, so toJSON writes it.
  qlpack = kind: {
    language,
    name,
  }: let
    library = "codeql/${language}-all";
  in
    pkgs.writeText "qlpack.yml" (builtins.toJSON ({
        inherit name;
        version = "0.0.0";
      }
      // (
        if kind == "query"
        then {dependencies.${library} = "*";}
        else {
          dataExtensions = ["*.model.yml"];
          extensionTargets.${library} = "*";
          library = true;
        }
      )));

  build = kind: args: let
    problems = errors args;
    pack = {
      inherit (args) name;
      language = args.language or defaultLanguage;
    };
  in
    assert lib.assertMsg (problems == []) "codeql.mk${lib.toSentenceCase kind}Pack:\n${lib.concatStringsSep "\n" problems}";
      pkgs.runCommand "codeql-${kind}-pack-${lib.replaceStrings ["/"] ["-"] pack.name}" {
        nativeBuildInputs = lib.optional (kind == "query") engine;
        passthru.codeqlPack = pack // {inherit kind;};
        meta = {
          description = "CodeQL ${kind} pack ${pack.name} for ${pack.language}";
          inherit (engine.meta) license platforms;
        };
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        cp -R --no-preserve=mode ${args.src} pack # bare-commands: ok (stdenv builder PATH)
        cp ${qlpack kind pack} pack/qlpack.yml # bare-commands: ok (stdenv builder PATH)
        ${
          if kind == "query"
          then ''
            export HOME="$TMPDIR"
            codeql pack create pack --output="$TMPDIR/created"
            mv "$TMPDIR/created/${pack.name}/0.0.0" "$out" # bare-commands: ok (stdenv builder PATH)
          ''
          else ''mv pack "$out" # bare-commands: ok (stdenv builder PATH)''
        }
      '';
in {
  mkModelPack = build "model";
  mkQueryPack = build "query";
}
