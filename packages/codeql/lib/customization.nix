# `customizePackage spec` on an engine: a `codeql` that resolves extra packs by
# name and runs with extra programs on PATH, over the engine's own
# `share/codeql`, which is linked and never copied. Direct callers get a throw
# for a bad spec. Customizing the result appends to its spec.
#
# A spec is `{ queries ? []; models ? []; extraPackages ? []; }`. `queries` and
# `models` hold directories with a qlpack.yml or `mkQueryPack`/`mkModelPack`
# results. The wrapper hands CodeQL a config file (CODEQL_CONFIG_FILE) of
# `--additional-packs` with every pack, and, with models, `--model-packs` with
# one generated pack holding every model's data extensions: CodeQL keeps one
# value per config option, and applies a model pack only when it is named. See
# ../docs/codeql.md for the measurements and the merge with a consumer's own
# config file.
{
  engine,
  pkgs,
}: let
  inherit (pkgs) lib;
  fields = ["extraPackages" "models" "queries"];
  modelsName = "nix-agentic-tools/customized-models";
  # Interpolation copies a directory into the store; toString would not.
  storePath = entry: "${entry}";
  # The options the generated config file sets; a consumer config file that
  # sets one too cannot be merged without losing one side's packs.
  options = spec: ["--additional-packs"] ++ lib.optional (spec.models != []) "--model-packs";

  packErrors = field: kind:
    lib.imap1 (index: entry: let
      at = "`${field}.${toString index}`";
      tagged = entry.codeqlPack.kind or null;
    in
      if lib.isDerivation entry
      then lib.optional (tagged != null && tagged != kind) "${at} is a ${tagged} pack; put it in `${tagged}s`"
      else if builtins.isPath entry
      then lib.optional (!builtins.pathExists (entry + "/qlpack.yml")) "${at} (${toString entry}) holds no qlpack.yml"
      else ["${at} must be a directory or a pack derivation"]);

  errors = spec: let
    unknown = builtins.attrNames (builtins.removeAttrs spec fields);
    lists = builtins.filter (field: !builtins.isList (spec.${field} or [])) fields;
    names = lib.concatMap (entry: lib.optional (entry ? codeqlPack.name) entry.codeqlPack.name) (spec.queries or [] ++ spec.models or []);
  in
    lib.optional (unknown != []) "unknown field(s) ${lib.concatStringsSep ", " unknown}; expected ${lib.concatStringsSep ", " fields}"
    ++ map (field: "`${field}` must be a list") lists
    ++ lib.optionals (lists == []) (
      lib.concatLists (packErrors "queries" "query" (spec.queries or []))
      ++ lib.concatLists (packErrors "models" "model" (spec.models or []))
      ++ lib.concatLists (lib.imap1 (index: entry: lib.optional (!lib.isDerivation entry) "`extraPackages.${toString index}` must be a package") (spec.extraPackages or []))
      ++ map (name: "pack ${name} is given more than once") (lib.unique (builtins.filter (name: lib.count (other: other == name) names > 1) names))
    );

  checked = spec: let
    problems = errors spec;
  in
    assert lib.assertMsg (problems == []) "codeql.customizePackage:\n${lib.concatStringsSep "\n" problems}";
      lib.genAttrs fields (field: spec.${field} or []);

  # One model pack whose data extensions are every model pack's own, each
  # copied under its index without its qlpack.yml so the copy is no second
  # pack of the same name.
  aggregate = models:
    pkgs.runCommand "codeql-model-pack-customized" {
      nativeBuildInputs = [pkgs.jq pkgs.yq-go];
      meta = {inherit (engine.meta) license platforms;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out" # bare-commands: ok (stdenv builder PATH)
      targets='{}'
      extensions='[]'
      index=0
      for pack in ${lib.escapeShellArgs (map storePath models)}; do
        cp -R --no-preserve=mode "$pack" "$out/$index" # bare-commands: ok (stdenv builder PATH)
        rm -f "$out/$index/qlpack.yml" "$out/$index/codeql-pack.lock.yml" # bare-commands: ok (stdenv builder PATH)
        manifest="$(yq -o=json . "$pack/qlpack.yml")"
        targets="$(jq -n --argjson a "$targets" --argjson m "$manifest" '$a + ($m.extensionTargets // {})')"
        extensions="$(jq -n --argjson a "$extensions" --argjson m "$manifest" --arg i "$index" \
          '$a + [($m.dataExtensions // []) | if type == "array" then .[] else . end | "\($i)/\(.)"]')"
        index=$((index + 1))
      done
      jq -n --arg name ${modelsName} --argjson targets "$targets" --argjson extensions "$extensions" \
        '{name: $name, version: "0.0.0", library: true, extensionTargets: $targets, dataExtensions: $extensions}' \
        > "$out/qlpack.yml"
    '';

  build = spec: let
    models = lib.optional (spec.models != []) (aggregate spec.models);
    packs = spec.queries ++ spec.models ++ models;
    config = pkgs.writeText "codeql-config" (lib.concatLines ([
        "--additional-packs ${lib.concatMapStringsSep ":" storePath packs}"
      ]
      ++ lib.optional (models != []) "--model-packs ${modelsName}"));
    coreutils = "${pkgs.coreutils}/bin";
    grep = "${pkgs.gnugrep}/bin/grep";
    # With packs, the wrapper points CODEQL_CONFIG_FILE at its config. A
    # consumer's own file (CODEQL_CONFIG_FILE, else CodeQL's per-user default)
    # is merged: theirs first, then ours, in a temporary file that lives as
    # long as this process. A file that already holds every line of ours is a
    # codeql this wrapper started, and is used as it is.
    configure = ''
      ours=${config}
      theirs="''${CODEQL_CONFIG_FILE:-''${HOME:+$HOME/.config/codeql/config}}"
      if [ -z "$theirs" ] || [ ! -e "$theirs" ]; then
        export CODEQL_CONFIG_FILE="$ours"
        exec "$codeql" "$@"
      fi
      if ! ${grep} -qvxFf "$theirs" "$ours"; then
        exec "$codeql" "$@"
      fi
      if ${grep} -qE -- '${lib.concatStringsSep "|" (options spec)}' "$theirs"; then
        echo "codeql: $theirs sets ${lib.concatStringsSep " or " (options spec)}, which this customized codeql sets from customizePackage." >&2
        echo "codeql: CodeQL keeps one value per option, so one side's packs would be lost; give those packs to customizePackage instead." >&2
        exit 2
      fi
      merged="$(${coreutils}/mktemp)"
      trap '${coreutils}/rm -f "$merged"' EXIT
      # The echo ends a last line that has no newline, which would otherwise
      # run into our first line.
      { ${coreutils}/cat "$theirs"; echo; ${coreutils}/cat "$ours"; } > "$merged"
      export CODEQL_CONFIG_FILE="$merged"
      status=0
      "$codeql" "$@" || status=$?
      exit "$status"
    '';
    wrapper = pkgs.writeShellApplication {
      name = "codeql";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :
        codeql=${engine}/bin/codeql
        ${lib.optionalString (spec.extraPackages != []) ''export PATH="${lib.makeBinPath spec.extraPackages}''${PATH:+:$PATH}"''}
        ${
          if packs == []
          then ''exec "$codeql" "$@"''
          else configure
        }
      '';
    };
  in
    pkgs.runCommand "${engine.pname}-customized-${engine.version}" {
      passthru = {
        inherit (engine) mkModelPack mkQueryPack;
        codeqlSpec = spec;
        customizePackage = more: build (lib.zipAttrsWith (_: lib.concatLists) [spec (checked more)]);
        unwrapped = engine;
      };
      meta = {inherit (engine.meta) description license mainProgram platforms;};
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/bin" "$out/share" # bare-commands: ok (stdenv builder PATH)
      ln -s ${wrapper}/bin/codeql "$out/bin/codeql"
      ln -s ${engine}/share/codeql "$out/share/codeql"
    '';
in
  spec: build (checked spec)
