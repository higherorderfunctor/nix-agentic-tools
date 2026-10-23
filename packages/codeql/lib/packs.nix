# A pack spec (./specs.nix) realized against one engine: the pack directory,
# with a qlpack.yml rendered by one function for both kinds. A query pack is
# precompiled with `codeql pack create`, offline, against the engine's bundled
# `codeql/<language>-all` or its validated custom library. A language engine
# supplies its default language; other engines require an explicit language. customizePackage reports `errors` and calls `realize`. See
# ../docs/customize.md.
{
  engine,
  engineName,
  extractors ? [],
  languages,
  libraries ? [],
  pkgs,
  specs,
}: let
  inherit (pkgs) lib;
  customLibraries = lib.listToAttrs (map (entry: lib.nameValuePair entry.language entry) libraries);
  supported = lib.unique (languages ++ builtins.attrNames customLibraries);
  searchPath = lib.concatStringsSep ":" (map (entry: "${entry.src}") extractors ++ ["${engine}/share/codeql"]);
  # Source validation runs in each consuming build, including customization
  # without queries. Derivation-backed inputs never need evaluation-time reads.
  validate =
    lib.concatMapStrings (extractor: let
      library = customLibraries.${extractor.language};
      descriptor = lib.escapeShellArg "${extractor.src}/codeql-extractor.yml";
      manifest = lib.escapeShellArg "${library.src}/qlpack.yml";
      language = lib.escapeShellArg extractor.language;
      name = lib.escapeShellArg library.name;
      schema = lib.escapeShellArg library.schema;
    in ''
      if [ "$(yq -r '.name' ${descriptor})" != ${language} ]; then
        echo 'codeql: extractor language mismatch: '${language} >&2
        exit 1
      fi
      if [ "$(yq -r '.name' ${manifest})" != ${name} ] || [ "$(yq -r '.library' ${manifest})" != true ] || [ "$(yq -r '.dbscheme' ${manifest})" != ${schema} ]; then
        echo 'codeql: library manifest mismatch: '${name} >&2
        exit 1
      fi
      if ! cmp -s ${lib.escapeShellArg "${extractor.src}/${extractor.schema}"} ${lib.escapeShellArg "${library.src}/${library.schema}"}; then
        echo 'codeql: schema mismatch: '${language} >&2
        exit 1
      fi
    '')
    extractors;

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
    if supported == []
    then ["${lead}: codeql-bare carries no CodeQL libraries; realize pack specs with a language engine or codeql-full"]
    else if defaultLanguage == null && !(spec ? language)
    then ["${lead}: codeql-${engineName} needs `language` on the spec, one of ${lib.concatStringsSep ", " supported}"]
    else lib.optional (spec ? language && !(lib.elem spec.language supported)) "${lead}: `language` ${spec.language} is not one codeql-${engineName} carries (${lib.concatStringsSep ", " supported})";

  # The one qlpack.yml renderer. JSON is YAML, so toJSON writes it.
  qlpack = kind: {
    language,
    name,
  }: let
    library =
      if customLibraries ? ${language}
      then customLibraries.${language}.name
      else "codeql/${language}-all";
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
      nativeBuildInputs = lib.optional (kind == "query") engine ++ lib.optional (extractors != []) pkgs.yq-go;
      passthru.codeqlPack = pack // {inherit kind;};
      meta = {
        description = "CodeQL ${kind} pack ${pack.name} for ${pack.language}";
        inherit (engine.meta) license platforms;
      };
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${validate}
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
          ${lib.optionalString (libraries != []) ''
            # CodeQL preserves dependency modes, then rewrites their manifests.
            mkdir libraries # bare-commands: ok (stdenv builder PATH)
            ${lib.concatImapStringsSep "\n" (index: entry: ''cp -RL --no-preserve=mode ${lib.escapeShellArg "${entry.src}"} libraries/${toString index} # bare-commands: ok (stdenv builder PATH)'') libraries}
          ''}
          codeql pack create pack --output="$TMPDIR/created" ${lib.optionalString (libraries != []) ''--additional-packs="$PWD/libraries"''} ${lib.escapeShellArgs (
            lib.optionals (extractors != []) ["--search-path" searchPath]
          )}
          mv "$TMPDIR/created/${pack.name}/0.0.0" "$out" # bare-commands: ok (stdenv builder PATH)
        ''
        else ''mv pack "$out" # bare-commands: ok (stdenv builder PATH)''
      }
    '';
in {
  inherit errors realize searchPath validate;
}
