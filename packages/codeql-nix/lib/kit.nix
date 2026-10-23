# F0 and S1 share the audited pins, vendoring and private syntax fixture.
{pkgs}: let
  fixture = ../checks/fixtures/bootstrap;
  grammar = pkgs.fetchFromGitHub {
    hash = "sha256-sS39i8TCtArwKoq3DFpxaaeZEuRiC1DUTZVPJ+mcPfE=";
    owner = "nix-community";
    repo = "tree-sitter-nix";
    rev = "38a15330421d20f3a4d380759f9634d39ba3d8ec";
  };
  kit = pkgs.fetchFromGitHub {
    hash = "sha256-o9cS+5joKXdUN8fOuUyl/yMMIzI4sKxdotljfMJ5by0=";
    owner = "github";
    repo = "codeql";
    rev = "a1575b98a8cc19bcfa7bb6cb41be688cb3dae65c";
  };
  source = pkgs.runCommand "nixql-bootstrap-source" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/upstream/shared" # bare-commands: ok
    cp ${fixture + "/Cargo.toml"} "$out/Cargo.toml" # bare-commands: ok
    cp ${fixture + "/Cargo.lock"} "$out/Cargo.lock" # bare-commands: ok
    cp -r ${fixture + "/src"} "$out/src" # bare-commands: ok
    chmod -R u+w "$out/src" # bare-commands: ok
    cp ${../src/generate.rs} "$out/src/bin/nixql-generate-raw.rs" # bare-commands: ok
    cp ${../src/anchors.rs} "$out/src/bin/nixql-anchors.rs" # bare-commands: ok
    for crate in tree-sitter-extractor yeast yeast-macros yeast-schema; do
      cp -r ${kit}/shared/"$crate" "$out/upstream/shared/" # bare-commands: ok
    done
    cp -r ${grammar} "$out/grammar" # bare-commands: ok
  '';
in {
  inherit grammar kit;
  syntaxFixture = pkgs.rustPlatform.buildRustPackage {
    cargoHash = "sha256-ewSoza879MQSji9vVZxP81htnxSnDURD9T+iYMEhzrw=";
    doCheck = false;
    pname = "nixql-bootstrap";
    src = source;
    version = "0.0.0";
  };
}
