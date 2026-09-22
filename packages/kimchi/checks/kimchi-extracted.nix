# Drift and collision checks for Kimchi's two source-derived settings surfaces.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    package = self.packages.${system}.kimchi;
    inherit (package.passthru) extracted extractionSources;
    committed = ../extracted.json;
    extractor = ../extract/extract.py;
  in {
    kimchi-extracted = pkgs.runCommand "kimchi-extracted-drift" {} ''
      jq="${pkgs.jq}/bin/jq"
      if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
        '$a == $b' > /dev/null; then
        echo "ok — packages/kimchi/extracted.json matches the pinned Kimchi and pi sources" > "$out"
      else
        echo "FAIL: packages/kimchi/extracted.json is out of sync with its extraction sources." >&2
        echo "--- committed ---" >&2
        "$jq" -S . ${committed} >&2
        echo "--- extracted ---" >&2
        "$jq" -S . ${extracted} >&2
        echo "" >&2
        echo "Regenerate: nix build .#kimchi.passthru.extracted --no-link --print-out-paths" >&2
        echo "then copy the result over packages/kimchi/extracted.json, format it, and git add it." >&2
        exit 1
      fi
    '';

    kimchi-extracted-harness-guard =
      pkgs.runCommand "kimchi-extracted-harness-guard" {
        nativeBuildInputs = [pkgs.python3];
      } ''
        cp -r ${extractionSources.kimchi} "$TMPDIR/kimchi-source"
        chmod -R u+w "$TMPDIR/kimchi-source"
        substituteInPlace "$TMPDIR/kimchi-source/src/config.ts" \
          --replace-fail 'const parsed = JSON.parse(raw)' $'const parsed = JSON.parse(raw)\n\t\tvoid parsed.harness'

        if fake_output=$(${pkgs.python3}/bin/python3 ${extractor} \
            --kimchi-source "$TMPDIR/kimchi-source" \
            --kimchi-version ${package.version} \
            --out "$TMPDIR/fake.json" \
            --pi-package ${extractionSources.pi} 2>&1); then
          echo "FAIL: extraction accepted a top-level config.json harness key" >&2
          exit 1
        else
          fake_status=$?
        fi
        expected="kimchi-extract: config.json exposes a top-level 'harness' key; this collides with the reserved harness settings namespace"
        if [ "$fake_output" != "$expected" ]; then
          echo "FAIL: collision guard emitted an unexpected diagnostic:" >&2
          echo "$fake_output" >&2
          exit 1
        fi

        ${pkgs.python3}/bin/python3 ${extractor} \
          --kimchi-source ${extractionSources.kimchi} \
          --kimchi-version ${package.version} \
          --out "$TMPDIR/real.json" \
          --pi-package ${extractionSources.pi}
        {
          echo "fake (exit $fake_status): $fake_output"
          echo "real (exit 0): kimchi-extract: config.json harness guard passed"
        } > "$out"
      '';
  };
}
