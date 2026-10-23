# One configured engine for the dev task and fixture check; query packs use
# the same external extractor and library through customizePackage.
{
  engine,
  extractor,
  pkgs,
}: let
  inherit (pkgs) lib;
  configured = engine.customizePackage {
    searchPath = [extractor ../ql/eval];
  };
  queries = (import ./specs.nix {inherit lib;}).mkQueryPack {
    language = "nix";
    name = "nix-agentic-tools/nix-queries";
    src = ../ql/nix;
  };
in {
  createDatabase = import ../../../lib/strict-shell-application.nix pkgs {
    name = "nix-codeql-create-database";
    runtimeInputs = [pkgs.coreutils pkgs.gitMinimal pkgs.gnutar];
    text = ''
      if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: nix-codeql-create-database <state-directory> [<fixture-tree>]" >&2
        exit 2
      fi
      ${pkgs.coreutils}/bin/mkdir -p "$1"
      state="$(realpath "$1")"
      for path in "$state/source" "$state/db"; do
        if [ -e "$path" ]; then rm -r -- "$path"; fi
      done
      ${pkgs.coreutils}/bin/mkdir "$state/source"
      if [ "$#" -eq 2 ]; then
        ${pkgs.coreutils}/bin/cp -R --no-preserve=mode "$2/." "$state/source/"
      else
        git archive HEAD | tar -x -C "$state/source"
      fi
      exec ${configured}/bin/codeql database create "$state/db" \
        --language=nix --build-mode=none --source-root="$state/source" \
        --threads="''${NIX_BUILD_CORES:-2}"
    '';
  };
  engine = configured;
  extractorManifest = "${extractor}/extractor/codeql-extractor.yml";
  warmEngine = configured.customizePackage {queries = [queries];};
  inherit queries;
}
