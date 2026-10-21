# The `network` fact's query, model packs and transform (lib/network.nix) on
# the fixture tree under ./fixtures/network, laid out as the release database
# is: Kimchi's src/ and a pi package with esbuild bundle chunks, one of them
# minified. Every row of the fact must equal ./fixtures/network-expected.txt,
# one line per call-site target, then one per URL literal no call site reads.
# The negative controls (a docs-only URL, a browser-only URL, a local
# function named fetch, an unrelated minified call) are expected only as
# unattributed literals. `$out` holds the fact JSON only. x86_64-linux only,
# as the engine is.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru) codeql network;
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    kimchi-codeql-network = let
      fact = network.factOf "network-fixture" (codeql.databaseOf "network-fixture" ./fixtures/network);
    in
      pkgs.runCommand "kimchi-codeql-network" {nativeBuildInputs = [pkgs.diffutils pkgs.jq];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        # Every field in order, `-` for null.
        jq -r '
          (.callSites[] | . as $site | .targets[]
            | [$site.readBy, "\($site.file):\($site.line)", $site.library, ($site.bundledModule // "-"), .kind, .value, (.host // "-"), .origin]),
          (.unattributed[] | ["unattributed", .readBy, "\(.file):\(.line)", .value, (.host // "-")])
          | join(" ")' ${fact} > rows.txt
        if ! diff -u ${./fixtures/network-expected.txt} rows.txt >&2; then
          echo "kimchi-codeql-network: the fixture's network rows differ from fixtures/network-expected.txt" >&2
          exit 1
        fi
        cp ${fact} "$out"
      '';
  };
}
