# A real Nix pack compiled by mkQueryPack, external language discovery and
# strict-header classification over fixtures only. No scan of this repo gates CI.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    codeql-nix-strict-header = let
      packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
      nixCodeql = packages.codeql-extractor-nix.codeql;
      custom = nixCodeql.engine.customizePackage {queries = [nixCodeql.queries];};
    in
      pkgs.runCommand "codeql-nix-strict-header" {
        nativeBuildInputs = [custom pkgs.jq];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR" LC_ALL=C
        codeql resolve languages --format=json | jq -e 'has("nix")'
        # A nested codeql reads the merged config without losing search-path.
        mkdir "$TMPDIR/run"
        printf '%s\n' '--threads 2' > "$TMPDIR/consumer"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer" codeql resolve languages --format=json | jq -e 'has("nix")'
        generated=("$TMPDIR"/run/codeql-config-*)
        CODEQL_CONFIG_FILE="''${generated[0]}" codeql resolve languages --format=json | jq -e 'has("nix")'
        printf '%s\n' '--search-path /does-not-exist' > "$TMPDIR/clash"
        status=0
        CODEQL_CONFIG_FILE="$TMPDIR/clash" codeql resolve languages 2> "$TMPDIR/clash.err" || status=$?
        [ "$status" = 2 ]
        grep -q customizePackage "$TMPDIR/clash.err"
        ${lib.getExe nixCodeql.createDatabase} "$TMPDIR/fixture" ${./fixtures/nix-project}
        pack=${builtins.head custom.packs.queries}
        [ -n "$(find "$pack" -name '*.qlx' -print -quit)" ]
        codeql database run-queries "$TMPDIR/fixture/db" nix-agentic-tools/nix-queries --threads=2 --ram=4096
        codeql bqrs decode --format=json "$TMPDIR/fixture/db/results/nix-agentic-tools/nix-queries/StrictHeader.bqrs" \
          | jq -r '."#select".tuples[] | "\(.[3]) \(.[0]) \(.[1]) \(.[2])"' | sort -n > "$out"
        diff -u ${./fixtures/nix-expected.txt} "$out"
      '';
  };
}
