# Chunk 5a fixture matrix: backend × format × method × shape, generated with
# cartesianProduct. Evaluation only, through the real backend modules: a valid
# cell asserts its normalized plan, its sink (native link or engine plan) and
# its secret edge; an impossible cell asserts its exact named refusal.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  files2 = import ../lib/files/default.nix {inherit lib pkgs;};
  target = "matrix";
  tree = ./fixtures/tree;
  # Written independently of the walker; bin/tool is executable.
  treeLeaves = ["bin/tool" "nested/deep/leaf.md"];
  # One document per format; json/toml/yaml documents are keyed so 5b can
  # execute `rw` on them.
  documents = {
    json = ''{"k": "v"}'';
    markdown = "# k\n";
    raw = "k\n";
    toml = ''k = "v"'';
    yaml = "k: v\n";
  };
  cells = lib.cartesianProduct {
    backend = ["devenv" "hm"];
    format = ["json" "markdown" "raw" "toml" "yaml"];
    method = ["ro" "rw" "symlink"];
    shape = ["executable" "recursive" "run" "source" "text" "value"];
  };
  content = format: let
    text = documents.${format};
  in {
    executable = {
      content.text = text;
      executable = true;
    };
    recursive = {
      content.source = tree;
      recursive = true;
    };
    run.content.run = "${pkgs.coreutils}/bin/printf '%s' ${lib.escapeShellArg text}";
    source.content.source = builtins.toFile "matrix.${format}" text;
    text.content.text = text;
    value.content.value.k = "v";
  };
  declare = cell: {inherit (cell) format method;} // (content cell.format).${cell.shape};
  # The engine document's refusal table, in its row order; the first match wins.
  keyless = format: builtins.elem format ["markdown" "raw"];
  refusals = [
    {
      message = "content.value requires json, toml or yaml format";
      when = cell: cell.shape == "value" && keyless cell.format;
    }
    {
      message = "rw requires json, toml or yaml format";
      when = cell: cell.method == "rw" && keyless cell.format;
    }
    {
      message = "rw cannot be recursive";
      when = cell: cell.shape == "recursive" && cell.method == "rw";
    }
    {
      message = "content.run requires ro or rw method";
      when = cell: cell.shape == "run" && cell.method == "symlink";
    }
  ];
  refusal = cell: lib.findFirst (row: row.when cell) null refusals;
  leaves = cell:
    if cell.shape == "recursive"
    then map (leaf: "${target}/${leaf}") treeLeaves
    else [target];
  expectedContent = cell: leaf: let
    declared = (content cell.format).${cell.shape}.content;
  in
    if cell.shape == "recursive"
    then {source = tree + lib.removePrefix target leaf;}
    else declared;
  expectedPlan = cell:
    map (path: {
      content = expectedContent cell path;
      executable =
        if cell.shape == "executable"
        then true
        else null;
      inherit (cell) format method;
      inherit path;
      rendered =
        if cell.shape == "value"
        then "files2-value.${cell.format}"
        else null;
    }) (leaves cell);
  summary = item: {
    content = builtins.removeAttrs item.content ["rendered"];
    inherit (item) executable format method path;
    rendered = item.content.rendered.name or null;
  };
  # Path sources link to that exact path; built content (text, value) links to
  # a store file, so only its executable flag is compared.
  expectedNative = cell:
    lib.genAttrs (lib.optionals (cell.method == "symlink") (leaves cell)) (leaf: {
      executable =
        if cell.shape == "executable"
        then true
        else null;
      source = let
        declared = expectedContent cell leaf;
      in
        if declared ? source
        then toString declared.source
        else null;
    });
  nativeSummary = entry: {
    executable = entry.executable or null;
    source =
      if lib.isDerivation entry.source
      then null
      else toString entry.source;
  };
  backends = import ./backends.nix {inherit harness lib pkgs;};
  evaluate = cell: let
    config = backends.evaluate cell.backend {files2.${target} = declare cell;};
  in {
    inherit config;
    sink = backends.sinks.${cell.backend};
    planArgs = {
      inherit (cell) backend;
      files = config.ai.files2;
      namespace = "ai";
    };
  };
  check = cell: let
    inherit (evaluate cell) config planArgs sink;
    apply = sink.entry config "apply";
    linked = lib.all (secret: builtins.elem secret apply.after) sink.secrets;
    unlinked = !lib.any (secret: builtins.elem secret apply.after) sink.secrets;
    row = refusal cell;
    label = what: "${cell.backend}/${cell.format}/${cell.method}/${cell.shape}: ${what}";
    planFile = pkgs.writeText "files2-ai-plan.json" (builtins.toJSON (files2.normalize planArgs));
  in
    if row != null
    then
      lib.optional (files2.validate planArgs != ''files2."${target}": ${row.message}'') (label "refusal message")
      ++ lib.optional (builtins.tryEval (builtins.seq (builtins.attrNames (sink.native config)) (sink.command apply))).success (label "accepted")
    else
      lib.optional (map summary (files2.normalize planArgs) != expectedPlan cell) (label "plan")
      ++ lib.optional (lib.mapAttrs (_: nativeSummary) (sink.native config) != expectedNative cell) (label "native sink")
      ++ lib.optional (!builtins.hasAttr (builtins.unsafeDiscardStringContext planFile.drvPath) (builtins.getContext (sink.command apply))) (label "engine plan")
      ++ lib.optional (
        if cell.shape == "run"
        then !linked
        else !unlinked
      ) (label "secret edge");
  refused = builtins.filter (cell: refusal cell != null) cells;
  # One rendered value per format, decoded at build time with that format's
  # own parser; a non-json rendering must not also parse as JSON.
  rendered = builtins.listToAttrs (map (cell: {
    name = cell.format;
    value = (builtins.head (files2.normalize (evaluate cell).planArgs)).content.rendered;
  }) (builtins.filter (cell: cell.shape == "value" && refusal cell == null) cells));
  decoder = pkgs.writeText "decode.py" ''
    import json, sys, tomllib, yaml
    loaders = {"json": json.loads, "toml": tomllib.loads, "yaml": yaml.safe_load}
    expected = json.loads(sys.argv[1])
    for format, path in zip(sys.argv[2::2], sys.argv[3::2]):
        with open(path, encoding="utf-8") as handle:
            data = handle.read()
        if loaders[format](data) != expected:
            sys.exit(f"{format}: decoded value differs")
        if format != "json":
            try:
                json.loads(data)
            except ValueError:
                continue
            sys.exit(f"{format}: rendered as JSON")
  '';
  failures =
    lib.optional (lib.any (row: !lib.any row.when cells) refusals) "unused refusal row"
    ++ lib.concatMap check cells;
in {
  checks.ai-module-matrix = assert lib.assertMsg (failures == []) "matrix: ${lib.concatStringsSep ", " failures}";
    pkgs.runCommandLocal "ai-module-matrix" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3.withPackages (ps: [ps.pyyaml])}/bin/python3 -I ${decoder} \
        ${lib.escapeShellArg (builtins.toJSON (content "json").value.content.value)} \
        ${lib.concatStringsSep " " (lib.mapAttrsToList (format: file: "${format} ${file}") rendered)}
      ${pkgs.coreutils}/bin/printf 'PASS: %s matrix cells, %s refused\n' ${toString (builtins.length cells)} ${toString (builtins.length refused)} > "$out"
    '';
}
