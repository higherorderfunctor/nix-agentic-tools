# Drift and collision checks for Kimchi's two source-derived settings surfaces.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    package = self.packages.${system}.kimchi;
    inherit (package.passthru) extracted extractionSources extractionSourceUrls;
    committed = ../extracted.json;
    extractor = ../extract/extract.mjs;

    runExtractor = source: output: pi: ''
      ${pkgs.nodejs}/bin/node ${extractor} \
        --annotations ${../extract/annotations.json} \
        --kimchi-source ${source} \
        --kimchi-source-url ${pkgs.lib.escapeShellArg extractionSourceUrls.kimchi} \
        --kimchi-version ${package.version} \
        --out ${output} \
        --pi-agent-core-package ${extractionSources.piAgentCore} \
        --pi-ai-package ${extractionSources.piAi} \
        --pi-package ${pi} \
        --pi-tui-package ${extractionSources.piTui} \
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
        # mutant SOURCE LABEL FILE FROM TO: a writable copy of SOURCE at
        # $TMPDIR/LABEL-source with FROM replaced by TO in FILE.
        mutant() {
          cp -r "$1" "$TMPDIR/$2-source"
          chmod -R u+w "$TMPDIR/$2-source"
          substituteInPlace "$TMPDIR/$2-source/$3" --replace-fail "$4" "$5"
        }
        kimchi=${extractionSources.kimchi}
        pi=${extractionSources.pi}

        mutant "$kimchi" collision src/config.ts \
          'const parsed = JSON.parse(raw)' $'const parsed = JSON.parse(raw)\n\t\tvoid parsed.harness'
        mutant "$kimchi" config-array-shape src/config.ts \
          'typeof p === "string"' 'typeof p === "number"'
        mutant "$kimchi" config-nested-shape src/config.ts \
          'typeof t.enabled === "boolean"' 'typeof t.enabled === "string"'
        mutant "$kimchi" config-parse-attribution src/config.ts \
          'JSON.parse(readFileSync(settingsPath ?? resolve(AGENT_CONFIG_DIR, "settings.json"), "utf-8"))' \
          'JSON.parse(readFileSync(settingsPath ?? KIMCHI_CONFIG_PATH, "utf-8"))'
        mutant "$kimchi" config-parse-unattributable src/config.ts \
          'JSON.parse(readFileSync(settingsPath ?? resolve(AGENT_CONFIG_DIR, "settings.json"), "utf-8"))' \
          'JSON.parse(readFileSync(settingsPath ?? resolve(AGENT_CONFIG_DIR, "state.json"), "utf-8"))'
        mutant "$kimchi" config-shape src/config.ts \
          'typeof parsed.apiKey === "string"' 'typeof parsed.apiKey === "number"'
        mutant "$kimchi" config-second-shape src/config.ts \
          'typeof parsed.llmEndpoint === "string"' 'typeof parsed.llmEndpoint === "number"'
        mutant "$kimchi" entry-imported-read src/auxiliary-files/resolver.ts \
          'if (env.XDG_DATA_HOME) {' 'if (env.XDG_DATA_HOME && !process.env.KIMCHI_CODING_AGENT_DIR) {'
        mutant "$kimchi" entry-late-write src/entry.ts \
          'installPasteInterceptor()' $'installPasteInterceptor()\nprocess.env.KIMCHI_NO_UPDATE_CHECK = "1"'
        mutant "$kimchi" entry-overwrite src/entry.ts \
          'process.env.KIMCHI_DISABLE_BUILTIN_PROVIDERS = "1"' $'process.env.KIMCHI_DISABLE_BUILTIN_PROVIDERS = "1"\nprocess.env.KIMCHI_NO_UPDATE_CHECK = "0"'
        mutant "$kimchi" entry-unread src/entry.ts \
          'const inheritedPiAgentDir = process.env.PI_CODING_AGENT_DIR' 'const inheritedPiAgentDir = undefined'
        mutant "$kimchi" inert-consumed src/config.ts \
          'export function getAgentConfigDir(): string {' $'export function getAgentConfigDir(): string {\n\tvoid loadConfig().maxToolResultChars'
        mutant "$kimchi" environment-app-name package.json \
          '"name": "kimchi"' '"name": "tau"'
        mutant "$kimchi" environment-stale-ignore src/agent-discovery/agents/opencode.ts \
          'const envOverride = process.env.OPENCODE_CONFIG' 'const envOverride = undefined'
        mutant "$kimchi" environment-unlisted src/extensions/skills-manager/skill-manager.ts \
          'process.env.SKILLS_DIR ??' 'process.env.SKILLS_DIR ?? process.env.UNLISTED_PROBE_DIR ??'
        mutant "$kimchi" harness-auto-default src/config.ts \
          'return parsed.autoDefaultApplied === true' 'return parsed.autoDefaultApplied === "yes"'
        mutant "$kimchi" harness-shape src/extensions/orchestration/model-roles.ts \
          'orchestrator: string' 'orchestrator: number'
        mutant "$kimchi" project-tier src/config.ts \
          'apiKey: projectExtras.apiKey ?? globalExtras.apiKey' 'apiKey: globalExtras.apiKey'
        mutant "$pi" pi-app-name dist/config.js \
          'export const APP_NAME = piConfigName || "pi";' 'export const APP_NAME = "pi";'

        expect_rejection() {
          label="$1"
          source="$2"
          expected="$3"
          pi_source="''${4:-$pi}"
          if rejected_output=$(
            {
              ${runExtractor "$source" ''"$TMPDIR/$label.json"'' ''"$pi_source"''}
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
        expect_rejection config-array-shape "$TMPDIR/config-array-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection config-nested-shape "$TMPDIR/config-nested-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection config-parse-attribution "$TMPDIR/config-parse-attribution-source" \
          'config.json key census changed; new=["autoDefaultApplied"]' >> "$TMPDIR/proof"
        expect_rejection config-parse-unattributable "$TMPDIR/config-parse-unattributable-source" \
          'cannot attribute the JSON read' >> "$TMPDIR/proof"
        expect_rejection config-shape "$TMPDIR/config-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection config-second-shape "$TMPDIR/config-second-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection entry-imported-read "$TMPDIR/entry-imported-read-source" \
          'src/entry.ts assigns KIMCHI_CODING_AGENT_DIR before reading it, but' >> "$TMPDIR/proof"
        expect_rejection entry-late-write "$TMPDIR/entry-late-write-source" \
          'src/entry.ts assigns KIMCHI_NO_UPDATE_CHECK after it suspends' >> "$TMPDIR/proof"
        expect_rejection environment-app-name "$TMPDIR/environment-app-name-source" \
          '"TAU_CODING_AGENT_SESSION_DIR"' >> "$TMPDIR/proof"
        expect_rejection environment-stale-ignore "$TMPDIR/environment-stale-ignore-source" \
          'staleIgnored=["OPENCODE_CONFIG"]' >> "$TMPDIR/proof"
        expect_rejection environment-unlisted "$TMPDIR/environment-unlisted-source" \
          'environment census changed; new=["UNLISTED_PROBE_DIR"]' >> "$TMPDIR/proof"
        expect_rejection harness-shape "$TMPDIR/harness-shape-source" \
          "harness/settings.json Kimchi additions validation shape changed" >> "$TMPDIR/proof"
        expect_rejection harness-auto-default "$TMPDIR/harness-auto-default-source" \
          "readAutoDefaultApplied no longer reads autoDefaultApplied === true" >> "$TMPDIR/proof"
        expect_rejection pi-app-name "$kimchi" \
          'pi APP_NAME in' "$TMPDIR/pi-app-name-source" >> "$TMPDIR/proof"

        ${runExtractor ''"$kimchi"'' ''"$TMPDIR/real.json"'' ''"$pi"''}
        ${runExtractor ''"$TMPDIR/project-tier-source"'' ''"$TMPDIR/project-tier.json"'' ''"$pi"''}
        if ${pkgs.jq}/bin/jq -e \
          '(.config.projectTier.honoredKeys | index("apiKey") == null and index("api_key") == null) and
           (.config.keys.apiKey.project == false and .config.keys.api_key.project == false)' \
          "$TMPDIR/project-tier.json" > /dev/null; then
          echo "project-tier (exit 0): removing projectExtras.apiKey removed apiKey and api_key" >> "$TMPDIR/proof"
        else
          echo "FAIL: project-tier mutation did not change compiler-derived project keys" >&2
          exit 1
        fi
        # The overwrite flag is derived from entry.ts, so an assignment before
        # any read flips a variable to fixed and a read before it flips back.
        ${runExtractor ''"$TMPDIR/entry-overwrite-source"'' ''"$TMPDIR/entry-overwrite.json"'' ''"$pi"''}
        ${runExtractor ''"$TMPDIR/entry-unread-source"'' ''"$TMPDIR/entry-unread.json"'' ''"$pi"''}
        for fixture in real:true:true entry-overwrite:false:true entry-unread:true:false; do
          IFS=: read -r label update_check agent_dir <<< "$fixture"
          if ${pkgs.jq}/bin/jq -e --argjson a "$update_check" --argjson b "$agent_dir" \
            '.environment.variables | (.KIMCHI_NO_UPDATE_CHECK.consumerOverridable == $a) and (.PI_CODING_AGENT_DIR.consumerOverridable == $b)' \
            "$TMPDIR/$label.json" > /dev/null; then
            echo "$label (exit 0): overridable KIMCHI_NO_UPDATE_CHECK=$update_check PI_CODING_AGENT_DIR=$agent_dir" >> "$TMPDIR/proof"
          else
            echo "FAIL: $label did not derive the expected entry.ts overwrite flags" >&2
            ${pkgs.jq}/bin/jq '.environment.variables | {KIMCHI_NO_UPDATE_CHECK, PI_CODING_AGENT_DIR}' "$TMPDIR/$label.json" >&2
            exit 1
          fi
        done
        # Inertness is derived too: one consumer of the loaded value clears it.
        ${runExtractor ''"$TMPDIR/inert-consumed-source"'' ''"$TMPDIR/inert-consumed.json"'' ''"$pi"''}
        for fixture in real:true inert-consumed:null; do
          IFS=: read -r label inert <<< "$fixture"
          if ${pkgs.jq}/bin/jq -e --argjson inert "$inert" \
            '.config.keys | (.maxToolResultChars.inert == $inert) and .mcpSearch.inert and .mcpSearchLimit.inert' \
            "$TMPDIR/$label.json" > /dev/null; then
            echo "$label (exit 0): maxToolResultChars inert=$inert" >> "$TMPDIR/proof"
          else
            echo "FAIL: $label did not derive the expected inert config keys" >&2
            ${pkgs.jq}/bin/jq '.config.keys | {maxToolResultChars, mcpSearch, mcpSearchLimit}' "$TMPDIR/$label.json" >&2
            exit 1
          fi
        done
        {
          ${pkgs.coreutils}/bin/cat "$TMPDIR/proof"
          echo "real (exit 0): kimchi-extract: config.json harness guard passed"
        } > "$out"
      '';
  };
}
