# `customizePackage spec` on an engine: a `codeql` that resolves extra packs by
# name and runs with extra programs on PATH, over the engine's own
# `share/codeql`, which is linked and never copied. Direct callers get a throw
# for a bad spec. Customizing the result appends to its spec.
#
# A spec is `{ queries ? []; models ? []; extraPackages ? []; }`. `queries` and
# `models` hold directories with a qlpack.yml, pack derivations, or
# `mkQueryPack`/`mkModelPack` specs (./specs.nix), each realized against this
# engine (./packs.nix). The wrapper hands CodeQL a config file (CODEQL_CONFIG_FILE) of
# `--additional-packs` with every pack, and, with models, `--model-packs` with
# one generated pack holding every model's data extensions: CodeQL keeps one
# value per config option, and applies a model pack only when it is named. See
# ../docs/customize.md for the measurements and the merge with a consumer's own
# config file.
{
  engine,
  engineName,
  # The languages the engine carries CodeQL libraries for.
  languages,
  pkgs,
}: let
  inherit (pkgs) lib;
  specs = import ./specs.nix {inherit lib;};
  packs = import ./packs.nix {inherit engine engineName languages pkgs specs;};
  fields = ["extraPackages" "models" "queries"];
  # The field each kind of pack goes in.
  fieldOf = {
    model = "models";
    query = "queries";
  };
  modelsName = "nix-agentic-tools/customized-models";
  # Interpolation copies a directory into the store; toString would not.
  storePath = entry: "${entry}";
  # The options the generated config file sets. The wrapper concatenates a
  # consumer's config lines with these and does not join option values, and
  # CodeQL keeps one value per option, so a consumer file that sets one too
  # would drop one side's packs.
  options = spec: ["--additional-packs"] ++ lib.optional (spec.models != []) "--model-packs";

  packErrors = field: kind:
    lib.imap1 (index: entry: let
      at = "`${field}.${toString index}`";
      tagged = entry.codeqlPack.kind or null;
      language = entry.codeqlPack.language or null;
    in
      if specs.isSpec entry
      then
        if entry.kind != kind
        then ["${at} (${entry.name}) is a ${entry.kind} pack spec; put it in `${fieldOf.${entry.kind}}`"]
        else packs.errors at entry
      else if lib.isDerivation entry
      then
        lib.optional (tagged != null && tagged != kind) "${at} is a ${tagged} pack; put it in `${fieldOf.${tagged}}`"
        ++ lib.optional (language != null && !(lib.elem language languages)) "${at} is a ${language} pack, which ${engine.pname} does not carry"
      else if builtins.isPath entry
      then lib.optional (!builtins.pathExists (entry + "/qlpack.yml")) "${at} (${toString entry}) holds no qlpack.yml"
      else ["${at} must be a path, a pack spec or a pack derivation"]);

  fail = problems: value:
    assert lib.assertMsg (problems == []) "codeql.customizePackage:\n${lib.concatStringsSep "\n" problems}"; value;

  # A pack spec becomes this engine's pack; every other entry is kept.
  realized = entry:
    if specs.isSpec entry
    then packs.realize entry
    else entry;

  # One spec's shape and entries, named by the caller's own indices, with each
  # pack spec realized.
  checked = spec: let
    unknown = builtins.attrNames (builtins.removeAttrs spec fields);
    lists = builtins.filter (field: !builtins.isList (spec.${field} or [])) fields;
  in
    fail (
      lib.optional (unknown != []) "unknown field(s) ${lib.concatStringsSep ", " unknown}; expected ${lib.concatStringsSep ", " fields}"
      ++ map (field: "`${field}` must be a list") lists
      ++ lib.optionals (lists == []) (
        lib.concatLists (packErrors "queries" "query" (spec.queries or []))
        ++ lib.concatLists (packErrors "models" "model" (spec.models or []))
        ++ lib.concatLists (lib.imap1 (index: entry: lib.optional (!lib.isDerivation entry) "`extraPackages.${toString index}` must be a package") (spec.extraPackages or []))
      )
    ) (lib.genAttrs fields (field: map realized (spec.${field} or [])));

  # Each store path once, in first-given order.
  uniqueEntries = lib.foldl' (kept: entry:
    if lib.elem (storePath entry) (map storePath kept)
    then kept
    else kept ++ [entry]) [];

  # Checked specs joined, each store path kept once, and then one pack name per
  # realized pack spec, over the joined spec, across appending calls too. A
  # plain directory's pack name is not read here; CodeQL reports a pack found in
  # two locations when the packs are used.
  merged = given: let
    spec = lib.mapAttrs (_: uniqueEntries) (lib.zipAttrsWith (_: lib.concatLists) given);
    names = lib.concatMap (entry: lib.optional (entry ? codeqlPack.name) entry.codeqlPack.name) (spec.queries ++ spec.models);
  in
    fail (map (name: "pack ${name} is given from more than one path") (lib.unique (builtins.filter (name: lib.count (other: other == name) names > 1) names))) spec;

  # One model pack whose data extensions are every model pack's own, each
  # copied under its index without its qlpack.yml so the copy is no second
  # pack of the same name, and without its codeql-pack.lock.yml, because a lock
  # file without its manifest is not kept.
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
    # is merged: theirs first, then ours, in a file named by its content. A
    # file that holds every line of ours, and sets ours's options with no
    # other line, is the merged file a codeql this wrapper started reads, and
    # is used as it is. Any other line setting those options is refused, so a
    # file holding ours as well cannot add packs that CodeQL would drop.
    configure = ''
      ours=${config}
      theirs="''${CODEQL_CONFIG_FILE:-''${HOME:+$HOME/.config/codeql/config}}"
      # /dev/null, or a link to it, is how a caller says it has no config file.
      if [ -z "$theirs" ] || [ "$theirs" -ef /dev/null ] || [ ! -e "$theirs" ]; then
        export CODEQL_CONFIG_FILE="$ours"
        exec "$codeql" "$@"
      fi
      if [ ! -f "$theirs" ] || [ ! -r "$theirs" ]; then
        echo "codeql: $theirs is not a regular readable file (the wrapper reads it more than once), so this customized codeql cannot merge its packs into it." >&2
        exit 2
      fi
      # grep exits 1 when it selects no line, and 2 on an error, which must
      # take no branch. A line that starts with the option, after leading
      # whitespace, sets it: CodeQL ignores a comment and the `--option=value`
      # form.
      owned=""
      found=0
      owned="$(${grep} -E -- '^[[:space:]]*(${lib.concatStringsSep "|" (options spec)})( |$)' "$theirs")" || found=$?
      case "$found" in
        0 | 1) ;;
        *) exit 2 ;;
      esac
      # foreign=0: theirs sets an option ours sets with a line that is not ours.
      foreign=1
      if [ -n "$owned" ]; then
        foreign=0
        ${grep} -qvxFf "$ours" <<<"$owned" || foreign=$?
      fi
      # covered=1: every line of ours is in theirs.
      covered=0
      ${grep} -qvxFf "$theirs" "$ours" || covered=$?
      case "$foreign:$covered" in
        1:1) exec "$codeql" "$@" ;;
        *2*) exit 2 ;;
      esac
      if [ -n "$owned" ]; then
        echo "codeql: $theirs sets ${lib.concatStringsSep " or " (options spec)}, which this customized codeql sets from customizePackage." >&2
        echo "codeql: the wrapper adds its lines to yours and does not join option values, and CodeQL keeps one value per option, so one side's packs would be lost; give those packs to customizePackage instead." >&2
        exit 2
      fi
      # The echo ends a last line that has no newline, which would otherwise
      # run into our first line. The merged file is named by its content and
      # outlives this wrapper, which execs codeql, so a codeql that codeql
      # starts reads the same file. Each run writes it again and renames it into
      # place, never trusting a file already under that name. It goes under
      # XDG_RUNTIME_DIR when that is a writable directory, else TMPDIR, else
      # /tmp.
      dir="''${XDG_RUNTIME_DIR:-}"
      if [ -z "$dir" ] || [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        dir="''${TMPDIR:-/tmp}"
      fi
      tmp="$(${coreutils}/mktemp "$dir/codeql-config.XXXXXXXX")"
      { ${coreutils}/cat "$theirs"; echo; ${coreutils}/cat "$ours"; } > "$tmp"
      sum="$(${coreutils}/sha256sum "$tmp")"
      merged="$dir/codeql-config-$(${coreutils}/id -u)-''${sum%% *}"
      ${coreutils}/mv -fT "$tmp" "$merged"
      export CODEQL_CONFIG_FILE="$merged"
      exec "$codeql" "$@"
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
        customizePackage = more: build (merged [spec (checked more)]);
        packs = {inherit (spec) models queries;};
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
  spec: build (merged [(checked spec)])
