{
  inputs,
  lib,
  pkgs,
}: let
  # Syntax generation stays independent of models.
  kit = import ./kit.nix {inherit pkgs;};
  syntaxPins = pkgs.writeText "nixql-generation-pins.json" (builtins.toJSON {
    grammar = kit.grammar.rev;
    kit = kit.kit.rev;
  });
  # Model generation uses the shared generated-file formatter.
  modelPython = pkgs.python3.withPackages (ps: [ps.tree-sitter ps.tree-sitter-grammars.tree-sitter-cpp]);
  models = (import ../../../lib/generated.nix {inherit lib;} pkgs).mkTree {
    inherit treefmt;
    files = {
      "builtins.json" = {
        source = "${rawModels}/builtins.json";
        type = "json";
      };
      "builtins.qll" = {
        source = "${rawModels}/builtins.qll";
        type = "raw";
      };
    };
    guards.parseCompare = true;
    name = "nixql-models";
    runtime = "codeql-nix";
  };
  rawModels = pkgs.runCommand "nixql-raw-models" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${modelPython}/bin/python3 ${../models/builtins}/generate.py \
      --nix ${pkgs.nix}/bin/nix --source ${pkgs.nix.src} --output "$out"
  '';
  treefmt = (inputs.treefmt-nix.lib.evalModule pkgs ../../../lib/treefmt-module.nix).config;
  # Runtime coordination reads the generated model fingerprint at build time.
  pins = pkgs.runCommand "nixql-generation-pins.json" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])) | {"model": json.load(open(sys.argv[2]))["modelVersion"]}))' \
      ${syntaxPins} ${models}/builtins.json > "$out"
  '';
  python = pkgs.python3.withPackages (ps: [ps.jsonschema]);
  strictShell = import ../../../lib/strict-shell-application.nix pkgs;
  inherit (builtins.fromJSON (builtins.readFile ../../codeql/sources.json)) version;
in
  assert lib.assertMsg (version == "2.27.3") "nixql: re-audit the kit pin when the engine changes"; rec {
    coordinator = strictShell {
      name = "nixql-extract";
      text = ''
        exec ${python}/bin/python3 ${../.}/src/extract.py \
          ${kit.syntax}/bin/nixql-anchors ${../schema} \
          ${generated}/nix.dbscheme ${pins} ${pkgs.nix}/bin/nix
      '';
    };
    extractor = pkgs.runCommand "nixql-extractor" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/tools" # bare-commands: ok
      cp ${library}/nix.dbscheme ${library}/nix.dbscheme.stats "$out/" # bare-commands: ok
      cat > "$out/codeql-extractor.yml" <<'MANIFEST' # bare-commands: ok
      build_modes: [none]
      column_kind: utf8
      display_name: Nix
      file_types:
        - extensions: [.nix]
          name: nix
      legacy_qltest_extraction: true
      name: nix
      options:
        inputs:
          title: Admitted pinned input roots as JSON
          type: string
        targets:
          title: Target discovery expression path
          type: string
      version: 0.0.0
      MANIFEST
      for hook in autobuild index-files qltest; do
        ln -s ${coordinator}/bin/nixql-extract "$out/tools/$hook.sh"
      done
    '';
    generated = pkgs.runCommand "nixql-generated" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${generator}/bin/nixql-generate "$out"
    '';
    generator = strictShell {
      name = "nixql-generate";
      text = ''
        if [[ "$#" != 1 ]]; then
          echo 'usage: nixql-generate OUTPUT_DIRECTORY' >&2
          exit 2
        fi
        exec ${pkgs.python3}/bin/python3 ${../src/generate.py} \
          ${kit.syntax}/bin/nixql-generate-raw \
          ${../schema/evaluation.dbscheme} ${syntaxPins} "$1"
      '';
    };
    library = pkgs.runCommand "nixql-library" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out" # bare-commands: ok
      cp -r ${generated}/. "$out/" # bare-commands: ok
      chmod -R u+w "$out" # bare-commands: ok
      cp -rL ${../.}/ql/lib/. "$out/" # bare-commands: ok
      mkdir -p "$out/models" "$out/nix/internal/generated" # bare-commands: ok
      cp ${models}/builtins.json "$out/models/" # bare-commands: ok
      cp ${models}/builtins.qll "$out/nix/internal/generated/Builtins.qll" # bare-commands: ok
      printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$out/nix.dbscheme.stats"
    '';
    inherit models;
    queries = pkgs.runCommand "nixql-queries" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out" # bare-commands: ok
      cp -r ${../ql/queries}/. "$out/" # bare-commands: ok
    '';
    inherit (kit) syntax;
    syntaxDriver = strictShell {
      name = "nixql-syntax";
      text = ''
        if [[ "$#" != 2 ]]; then
          echo 'usage: nixql-syntax MANIFEST_JSON OUTPUT_DIRECTORY' >&2
          exit 2
        fi
        exec ${pkgs.python3}/bin/python3 ${../.}/src/syntax.py \
          ${kit.syntax}/bin/nixql-anchors ${../schema} \
          ${generated}/nix.dbscheme ${pins} "$@"
      '';
    };
  }
