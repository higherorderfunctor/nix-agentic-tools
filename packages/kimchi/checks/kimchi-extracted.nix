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
    extractor = ../extract/extract.mjs;

    runExtractor = source: output: ''
      ${pkgs.nodejs}/bin/node ${extractor} \
        --annotations ${../extract/annotations.json} \
        --kimchi-source ${source} \
        --kimchi-version ${package.version} \
        --out ${output} \
        --pi-package ${extractionSources.pi} \
        --typescript ${pkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js
    '';
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
        nativeBuildInputs = [pkgs.nodejs pkgs.typescript_5];
      } ''
        cp -r ${extractionSources.kimchi} "$TMPDIR/collision-source"
        cp -r ${extractionSources.kimchi} "$TMPDIR/config-shape-source"
        cp -r ${extractionSources.kimchi} "$TMPDIR/harness-shape-source"
        chmod -R u+w "$TMPDIR/collision-source" "$TMPDIR/config-shape-source" "$TMPDIR/harness-shape-source"

        substituteInPlace "$TMPDIR/collision-source/src/config.ts" \
          --replace-fail 'const parsed = JSON.parse(raw)' $'const parsed = JSON.parse(raw)\n\t\tvoid parsed.harness'
        substituteInPlace "$TMPDIR/config-shape-source/src/config.ts" \
          --replace-fail 'typeof parsed.apiKey === "string"' 'typeof parsed.apiKey === "number"'
        substituteInPlace "$TMPDIR/harness-shape-source/src/extensions/orchestration/model-roles.ts" \
          --replace-fail 'orchestrator: string' 'orchestrator: number'

        expect_rejection() {
          label="$1"
          source="$2"
          expected="$3"
          if rejected_output=$(
            {
              ${runExtractor "$source" ''"$TMPDIR/$label.json"''}
            } 2>&1
          ); then
            echo "FAIL: extraction accepted the $label mutation" >&2
            exit 1
          else
            rejected_status=$?
          fi
          case "$rejected_output" in
            *"$expected"*) ;;
            *)
              echo "FAIL: $label guard emitted an unexpected diagnostic:" >&2
              echo "$rejected_output" >&2
              exit 1
              ;;
          esac
          echo "$label (exit $rejected_status): $rejected_output"
        }

        expect_rejection collision "$TMPDIR/collision-source" \
          "config.json exposes a top-level 'harness' key" > "$TMPDIR/proof"
        expect_rejection config-shape "$TMPDIR/config-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection harness-shape "$TMPDIR/harness-shape-source" \
          "harness/settings.json Kimchi additions validation shape changed" >> "$TMPDIR/proof"

        ${runExtractor extractionSources.kimchi ''"$TMPDIR/real.json"''}
        {
          ${pkgs.coreutils}/bin/cat "$TMPDIR/proof"
          echo "real (exit 0): kimchi-extract: config.json harness guard passed"
        } > "$out"
      '';
  };
}
