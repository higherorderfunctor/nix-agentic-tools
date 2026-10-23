{
  lib,
  pkgs,
}: let
  inputs = import ./kit.nix {inherit pkgs;};
  pins = pkgs.writeText "nixql-generation-pins.json" (builtins.toJSON {
    grammar = inputs.grammar.rev;
    kit = inputs.kit.rev;
  });
  strictShell = import ../../../lib/strict-shell-application.nix pkgs;
  inherit (builtins.fromJSON (builtins.readFile ../../codeql/sources.json)) version;
in
  assert lib.assertMsg (version == "2.27.3") "nixql: re-audit the kit pin when the engine changes"; rec {
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
          ${inputs.syntaxFixture}/bin/nixql-generate-raw \
          ${../schema/evaluation.dbscheme} ${pins} "$1"
      '';
    };
    library = pkgs.runCommand "nixql-library" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out" # bare-commands: ok
      cp -r ${generated}/. "$out/" # bare-commands: ok
      chmod -R u+w "$out" # bare-commands: ok
      cp -rL ${../.}/ql/lib/. "$out/" # bare-commands: ok
      printf '<dbstats><typesizes/><stats/></dbstats>\n' > "$out/nix.dbscheme.stats"
    '';
    inherit (inputs) syntaxFixture;
    syntaxDriver = strictShell {
      name = "nixql-syntax";
      text = ''
        if [[ "$#" != 2 ]]; then
          echo 'usage: nixql-syntax MANIFEST_JSON OUTPUT_DIRECTORY' >&2
          exit 2
        fi
        exec ${pkgs.python3}/bin/python3 ${../src/syntax.py} \
          ${inputs.syntaxFixture}/bin/nixql-anchors ${../schema} \
          ${generated}/nix.dbscheme ${pins} "$@"
      '';
    };
  }
