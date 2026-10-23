# CI builds ONE engine, javascript, and only evaluates the other ten. Every
# engine is the same factory over a different asset (lib/mkEngine.nix), so a
# build of one exercises the shared body, and an evaluation of all eleven
# catches a broken call site or sources.json entry. Building all eleven would
# fetch 2.2 GB and unpack and patch 5 GB on every uncached run. See
# docs/codeql.md.
{
  lib,
  pkgs,
  self,
  ...
}: let
  sources = builtins.fromJSON (builtins.readFile ../sources.json);
  packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
  engines = map (engine: "codeql-${engine}") (builtins.attrNames (builtins.removeAttrs sources ["version"]));
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    # Every engine's drvPath, with its context discarded so nothing is built.
    # The uncustomized engine names must be the sources.json entries: a
    # recipe directory without an asset, or an asset without a recipe, fails.
    codeql-engines-eval = let
      found = builtins.filter (name: lib.hasPrefix "codeql-" name && packages.${name} ? customizePackage && !(packages.${name} ? unwrapped)) (builtins.attrNames packages);
      drvPaths = map (name: "${name} ${builtins.unsafeDiscardStringContext packages.${name}.drvPath}") engines;
    in
      assert lib.assertMsg (found == engines) "codeql-engines-eval: flat engines ${toString found} differ from sources.json's ${toString engines}";
        pkgs.writeText "codeql-engines-eval" (lib.concatLines drvPaths);

    # The javascript engine runs: its version is the pinned one and it
    # resolves its own extractor. Only names reach `$out`, so the check's
    # output holds no reference to the engine.
    codeql-javascript-smoke =
      pkgs.runCommand "codeql-javascript-smoke" {
        nativeBuildInputs = [packages.codeql-javascript pkgs.jq];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR"
        version="$(codeql version --format=terse)"
        if [ "$version" != ${lib.escapeShellArg sources.version} ]; then
          echo "codeql version is $version, expected ${sources.version}" >&2
          exit 1
        fi
        codeql resolve languages --format=json | jq -r 'keys[]' > "$TMPDIR/languages"
        if ! grep -qx javascript "$TMPDIR/languages"; then
          echo "codeql resolved no javascript extractor:" >&2
          cat "$TMPDIR/languages" >&2
          exit 1
        fi
        { echo "version $version"; sed 's/^/language /' "$TMPDIR/languages"; } > "$out"
        cat "$out"
      '';
  };
}
