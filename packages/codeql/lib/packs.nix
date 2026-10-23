# A pack spec (./specs.nix) realized against one engine: the pack directory,
# with a qlpack.yml rendered by one function for both kinds. A query pack is
# precompiled with `codeql pack create`, offline, against the engine's bundled
# `codeql/<language>-all`. A spec's language must be one the engine carries
# (`languages`): a language engine supplies its own, and codeql-full needs the
# spec to name one. customizePackage reports `errors` and calls `realize`. See
# ../docs/customize.md.
{
  engine,
  engineName,
  languages,
  libraries,
  pkgs,
  searchPath,
  specs,
}: let
  inherit (pkgs) lib;

  # The language a language bundle carries; the full bundle needs it named.
  defaultLanguage =
    if lib.elem engineName languages
    then engineName
    else null;

  # `errors at spec`: why this engine cannot realize `spec`, each message led by
  # `at`, the caller's own index.
  errors = at: spec: let
    lead = "${at} (${spec.name})";
  in
    if libraries == {}
    then ["${lead}: codeql-bare carries no CodeQL libraries; realize pack specs with a language engine or codeql-full"]
    else if defaultLanguage == null && !(spec ? language)
    then ["${lead}: codeql-${engineName} needs `language` on the spec, one of ${lib.concatStringsSep ", " (builtins.attrNames libraries)}"]
    else lib.optional (spec ? language && !(builtins.hasAttr spec.language libraries)) "${lead}: `language` ${spec.language} is not one codeql-${engineName} carries (${lib.concatStringsSep ", " (builtins.attrNames libraries)})";

  # The one qlpack.yml renderer. JSON is YAML, so toJSON writes it.
  qlpack = kind: {
    language,
    name,
  }: let
    library = libraries.${language};
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

  realize = spec: let
    inherit (spec) kind;
    pack = {
      inherit (spec) name;
      language = spec.language or defaultLanguage;
    };
  in
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
      cp -R --no-preserve=mode ${spec.src} pack # bare-commands: ok (stdenv builder PATH)
      if [ -e pack/qlpack.yml ]; then
        echo ${lib.escapeShellArg "codeql.mk${lib.toSentenceCase kind}Pack: ${specs.ownManifest}"} >&2
        exit 1
      fi
      cp --no-preserve=mode ${qlpack kind pack} pack/qlpack.yml # bare-commands: ok (stdenv builder PATH)
      ${
        if kind == "query"
        then ''
          export HOME="$TMPDIR"
          # pack create rewrites dependency manifests after copying them;
          # a raw external library in the store would copy read-only modes.
          ${lib.concatStringsSep "\n" (lib.imap1 (index: entry: ''cp -R --no-preserve=mode ${entry} "$TMPDIR/search-path-${toString index}" # bare-commands: ok (stdenv builder PATH)'') searchPath)}
          codeql pack create pack --output="$TMPDIR/created" ${lib.optionalString (searchPath != []) "--search-path=\"${lib.concatStringsSep ":" (lib.imap1 (index: _: "$TMPDIR/search-path-${toString index}") searchPath)}\""}
          mv "$TMPDIR/created/${pack.name}/0.0.0" "$out" # bare-commands: ok (stdenv builder PATH)
        ''
        else ''mv pack "$out" # bare-commands: ok (stdenv builder PATH)''
      }
    '';
in {
  inherit errors libraries realize;
}
