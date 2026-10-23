# Shared audited syntax producer, generation and preflight with pinned vendoring.
{pkgs}: let
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
  production = ../src;
  source = pkgs.runCommand "nixql-syntax-source" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    mkdir -p "$out/upstream/shared" # bare-commands: ok
    cp ${production}/Cargo.{toml,lock} "$out/" # bare-commands: ok
    cp ${production}/*.rs "$out/" # bare-commands: ok
    for crate in tree-sitter-extractor yeast yeast-macros yeast-schema; do
      cp -r ${kit}/shared/"$crate" "$out/upstream/shared/" # bare-commands: ok
    done
    cp -r ${grammar} "$out/grammar" # bare-commands: ok
  '';
in {
  inherit grammar kit;
  syntax = pkgs.rustPlatform.buildRustPackage {
    cargoHash = "sha256-ewSoza879MQSji9vVZxP81htnxSnDURD9T+iYMEhzrw=";
    doCheck = false;
    pname = "nixql-syntax";
    src = source;
    version = "0.0.0";
  };
}
