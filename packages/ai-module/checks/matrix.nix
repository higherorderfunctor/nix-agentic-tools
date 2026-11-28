# Fixture matrix: backend × format × method × shape, generated with
# cartesianProduct. Through the real backend modules, every valid cell checks
# normalization; representative cells check the sinks and secret edges.
# Single restrictions exercise backend rejection; exact
# diagnostics here pin markdown coverage and precedence, beyond eval.nix.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  fileLib = import ../lib/files/default.nix {inherit lib pkgs;};
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
  matchingRefusals = cell: builtins.filter (row: row.when cell) refusals;
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
      mode = null;
      inherit path;
      recursive = cell.shape == "recursive";
      rendered =
        if cell.shape == "value"
        then "files-value.${cell.format}"
        else null;
    }) (leaves cell);
  summary = item: {
    content = builtins.removeAttrs item.content ["rendered"];
    inherit (item) executable format method mode path recursive;
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
    config = backends.evaluate cell.backend {files.${target} = declare cell;};
  in {
    inherit config;
    sink = backends.sinks.${cell.backend};
    planArgs = {
      inherit (cell) backend;
      files = config.ai.files;
      namespace = "ai";
    };
  };
  readSinks = candidate: let
    inherit (evaluate candidate) config sink;
  in [
    (builtins.attrNames (sink.native config))
    (builtins.isString (sink.command (sink.entry config "apply")))
  ];
  # Backend wiring does not dispatch on format. Keep one format per
  # method and shape for the native sink and secret edge, and one plan
  # reference per content shape that exercises distinct normalization.
  applyCells = ["json/ro/value" "json/rw/run" "raw/ro/text" "raw/symlink/recursive"];
  check = cell: let
    inherit (evaluate cell) config planArgs sink;
    apply = sink.entry config "apply";
    linked = lib.all (secret: builtins.elem secret apply.after) sink.secrets;
    unlinked = !lib.any (secret: builtins.elem secret apply.after) sink.secrets;
    matches = matchingRefusals cell;
    planFile = pkgs.writeText "files-ai-plan.json" (builtins.toJSON (fileLib.normalize planArgs));
    # Force both sinks. The control repairs one invalid dimension, not the
    # backend; combined-invalid cells only add diagnostic precedence coverage.
    control =
      if cell.shape == "recursive" || cell.shape == "run"
      then cell // {method = "ro";}
      else cell // {format = "json";};
    shapeKey = "${cell.format}/${cell.method}/${cell.shape}";
    name = "${cell.backend}/${shapeKey}";
    representativeRefusal =
      (cell.method == "rw" && keyless cell.format && cell.shape == "text")
      || shapeKey == "json/rw/recursive"
      || shapeKey == "raw/symlink/run"
      || (cell.shape == "value" && keyless cell.format);
  in {
    inherit name;
    value = harness.checkRows name (
      if matches != []
      then
        lib.optionalAttrs (builtins.length matches == 1 && representativeRefusal) {
          "backend refuses the invalid declaration only" = harness.rejectsChange readSinks {
            valid = control;
            invalid = cell;
            expected = [(lib.optionals (control.method == "symlink") [target]) true];
          };
        }
        # A scalar method resolves identically in both backends. Keep the
        # markdown keyless cases and both overlapping restriction pairs once.
        // lib.optionalAttrs (builtins.elem name [
          "hm/markdown/rw/text"
          "hm/markdown/symlink/value"
          "hm/raw/rw/recursive"
          "hm/raw/rw/value"
        ]) {
          "validator names the destination and restriction" = fileLib.validate planArgs == ''files."${target}": ${(builtins.head matches).message}'';
        }
      else
        {
          "normalized plan preserves inputs and exact destination leaves" = map summary (fileLib.normalize planArgs) == expectedPlan cell;
        }
        // lib.optionalAttrs (builtins.elem shapeKey applyCells) {
          "apply references the exact normalized engine plan" = builtins.hasAttr (builtins.unsafeDiscardStringContext planFile.drvPath) (builtins.getContext (sink.command apply));
        }
        // lib.optionalAttrs (cell.format == "json") {
          "native sink neither drops links nor receives copies" = lib.mapAttrs (_: nativeSummary) (sink.native config) == expectedNative cell;
          "only run content waits for secrets" =
            if cell.shape == "run"
            then linked
            else unlinked;
        }
    );
  };
  refused = builtins.filter (cell: matchingRefusals cell != []) cells;
  # One rendered value per format, decoded at build time with that format's
  # own parser. YAML also accepts JSON, so exclude JSON for that rendering.
  rendered = builtins.listToAttrs (map (cell: {
    name = cell.format;
    value = (builtins.head (fileLib.normalize (evaluate cell).planArgs)).content.rendered;
  }) (builtins.filter (cell: cell.shape == "value" && matchingRefusals cell == []) cells));
  decoder = pkgs.writeText "decode.py" ''
    import json, sys, tomllib, yaml
    loaders = {"json": json.loads, "toml": tomllib.loads, "yaml": yaml.safe_load}
    expected = {"k": "v"}
    entries = dict(zip(sys.argv[1::2], sys.argv[2::2], strict=True))
    for format, path in entries.items():
        with open(path, encoding="utf-8") as handle:
            data = handle.read()
        if loaders[format](data) != expected:
            sys.exit(f"{format}: decoded value differs")
        if format == "yaml":
            try:
                json.loads(data)
            except ValueError:
                continue
            sys.exit(f"{format}: rendered as JSON")
  '';
in {
  checks.ai-module-matrix = assert harness.checkRows "files matrix" (builtins.listToAttrs (map check cells));
    pkgs.runCommandLocal "ai-module-matrix" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3.withPackages (ps: [ps.pyyaml])}/bin/python3 -I ${decoder} \
        ${lib.concatStringsSep " " (lib.mapAttrsToList (format: file: "${format} ${file}") rendered)}
      ${pkgs.coreutils}/bin/printf 'PASS: %s matrix combinations, %s invalid\n' ${toString (builtins.length cells)} ${toString (builtins.length refused)} > "$out"
    '';
}
