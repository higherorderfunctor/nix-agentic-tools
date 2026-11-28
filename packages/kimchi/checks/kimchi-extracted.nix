# Drift and collision checks for Kimchi's two source-derived settings surfaces.
# cspell:ignore odwyer
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkOwnerCheck;
    package = self.ciPackages.${system}.kimchi;
    inherit (package.passthru) extractionSources extractionSourceUrls;
    extractor = ../extract/extract.mjs;
    runExtractor = source: output: pi: ''
      ${pkgs.yq-go}/bin/yq -o=json '.' ${source}/pnpm-lock.yaml > "$TMPDIR/kimchi-lock.json"
      ${pkgs.nodejs}/bin/node ${extractor} \
        --annotations ${../extract/annotations.json} \
        --kimchi-lock "$TMPDIR/kimchi-lock.json" \
        --kimchi-source ${source} \
        --kimchi-source-url ${pkgs.lib.escapeShellArg extractionSourceUrls.kimchi} \
        --kimchi-version ${pkgs.lib.escapeShellArg package.version} \
        --out ${output} \
        --pi-agent-core-package ${extractionSources.piAgentCore} \
        --pi-ai-package ${extractionSources.piAi} \
        --pi-package ${pi} \
        --pi-tui-package ${extractionSources.piTui} \
        --typebox-package ${extractionSources.typebox} \
        --typescript ${pkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js
    '';
  in
    mkOwnerCheck {
      dir = ../extracted;
      # Every row declares x86_64-linux, the one system the CodeQL engine
      # behind the environment surface runs on; no other host extracts.
      extracted = pkgs.lib.optionalAttrs (system == "x86_64-linux") {${system} = package.passthru.extracted;};
      name = "kimchi";
      inherit package;
      results = package.passthru.extractedRules.results;
    }
    // {
      kimchi-extracted-harness-guard =
        pkgs.runCommand "kimchi-extracted-harness-guard" {
          nativeBuildInputs = [pkgs.nodejs pkgs.typescript_5];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          # mutant SOURCE LABEL FILE FROM TO: a writable copy of SOURCE at
          # $TMPDIR/LABEL-source with FROM replaced by TO in FILE.
          mutant() {
            cp -r "$1" "$TMPDIR/$2-source"
            chmod -R u+w "$TMPDIR/$2-source"
            substituteInPlace "$TMPDIR/$2-source/$3" --replace-fail "$4" "$5"
          }
          kimchi=${package.passthru.patchedSource}
          pi=${extractionSources.pi}

          mutant "$kimchi" collision src/config.ts \
            'const parsed = JSON.parse(raw)' $'const parsed = JSON.parse(raw)\n\t\tvoid parsed.harness'
          mutant "$kimchi" config-array-shape src/config.ts \
            'typeof p === "string"' 'typeof p === "number"'
          mutant "$kimchi" config-nested-shape src/config.ts \
            'typeof t.enabled === "boolean"' 'typeof t.enabled === "string"'
          mutant "$kimchi" config-timezone-alias-mutable src/config.ts \
            'const tc = parsed.tui' 'let tc = parsed.tui'
          timezone_call='const timezone = normalizeTuiTimezone(tc.timezone)'
          mutant "$kimchi" config-timezone-alias-value src/config.ts \
            "$timezone_call" $'const timezoneInput = tc.timezone\n\t\t\tconst timezone = normalizeTuiTimezone(timezoneInput)'
          mutant "$kimchi" config-timezone-bracket-literal src/config.ts \
            "$timezone_call" 'const timezone = normalizeTuiTimezone(tc["timezone"])'
          mutant "$kimchi" config-timezone-computed-key src/config.ts \
            "$timezone_call" 'const timezone = normalizeTuiTimezone(tc[String("timezone")])'
          mutant "$kimchi" config-timezone-guard src/config.ts \
            "$timezone_call" 'const timezone = normalizeTuiTimezone(tc.otherTimezone)'
          # Repoint readSurveyConfig's config.json parse: at the harness file its
          # `surveys` read must surface as an unknown harness key.
          survey_parse=$'function readSurveyConfig(surveyId: string, configPath: string): SurveyConfig | undefined {\n\ttry {\n\t\tconst parsed = JSON.parse(readFileSync('
          mutant "$kimchi" config-parse-attribution src/config.ts \
            "''${survey_parse}configPath, \"utf-8\"))" \
            "''${survey_parse}resolve(AGENT_CONFIG_DIR, \"settings.json\"), \"utf-8\"))"
          # Each inline mutant must fail with "is not bound to a local".
          # Counting these shapes as single named property reads could hide key
          # reads: a computed key, the whole object, required access, delete,
          # a shadowed reader, a detached property, or a property used as the
          # callee rather than an argument.
          inline_rejected=()
          inline_mutant() {
            inline_rejected+=("$1")
            mutant "$kimchi" "$@"
          }
          inline_config='readConfigObject(configPath)?.modelEffortDefaults'
          inline_mutant config-inline-computed src/config.ts \
            "$inline_config" 'readConfigObject(configPath)?.[String("modelEffortDefaults")]'
          inline_mutant config-inline-whole-object src/config.ts \
            "$inline_config" 'readConfigObject(configPath)'
          inline_mutant config-inline-required-access src/config.ts \
            "$inline_config" 'readConfigObject(configPath).modelEffortDefaults'
          inline_mutant config-inline-delete src/config.ts \
            "$inline_config" 'delete readConfigObject(configPath)?.modelEffortDefaults'
          inline_call="return parseModelEffortDefaults($inline_config)"
          inline_mutant config-inline-shadow src/config.ts \
            "$inline_call" $'function readConfigObject(_path: string) { return {} }\n\t'"$inline_call"
          inline_mutant config-inline-detached src/config.ts \
            "$inline_call" "const saved = $inline_config;"$'\n\t'"return parseModelEffortDefaults(saved)"
          inline_mutant config-inline-callee src/config.ts \
            "$inline_config" "$inline_config()"
          mutant "$kimchi" config-inline-unattributable src/config.ts \
            "$inline_config" 'readConfigObject(resolve(AGENT_CONFIG_DIR, "state.json"))?.modelEffortDefaults'
          mutant "$kimchi" config-scalar-shape src/config.ts \
            'typeof parsed.llmEndpoint === "string"' 'typeof parsed.llmEndpoint === "number"'
          mutant "$kimchi" duplicate-live-schema src/agent-discovery/agents/claude-code.ts \
            'import { homedir } from "node:os"' $'import { homedir } from "node:os"\ninterface FermentV2Settings {}'
          mutant "$kimchi" hand-shape-new-member src/config.ts \
            '		const enabled = parsed?.teleport?.compactHint?.enabled' $'\t\tif (typeof parsed?.teleport?.delayMs === "number") return false\n\t\tconst enabled = parsed?.teleport?.compactHint?.enabled'
          mutant "$kimchi" hand-shape-retyped src/config.ts \
            'return typeof seenAt === "string" && seenAt.length > 0' 'return typeof seenAt === "number"'
          semantic_reader=src/extensions/work-attribution/semantic.ts
          semantic_key='readConfigSetting("workSemanticMatching"'
          semantic_read="$semantic_key"', (value): value is boolean => typeof value === "boolean")'
          mutant "$kimchi" helper-computed-key "$semantic_reader" \
            "$semantic_key" 'readConfigSetting(String(Date.now())'
          mutant "$kimchi" helper-unknown-key src/extensions/session-name.ts \
            '"sessionNameModel"' '"sessionNameModelProbe"'
          mutant "$kimchi" helper-unresolved-guard "$semantic_reader" \
            "$semantic_read" 'readConfigSetting("semanticProbe", (value) => Boolean(value))'
          mutant "$kimchi" helper-named-guard src/extensions/ferment-v2/settings.ts \
            'readConfigSetting("fermentV2", isPlainObject)' 'readConfigSetting("fermentV2Probe", isPlainObject)'
          mutant "$kimchi" helper-guard-conflict "$semantic_reader" \
            "$semantic_key" 'readConfigSetting("sessionNameModel"'
          mutant "$kimchi" helper-retained-conflict src/extensions/ferment-v2/settings.ts \
            'readConfigSetting("fermentV2", isPlainObject)' \
            'readConfigSetting("fermentV2", (value) => typeof value === "string")'
          mutant "$kimchi" helper-known-unresolved src/extensions/ferment-v2/settings.ts \
            'readConfigSetting("fermentV2", isPlainObject)' \
            'readConfigSetting("fermentV2", (value) => Boolean(value))'
          mutant "$kimchi" helper-number-array "$semantic_reader" \
            "$semantic_read" 'readConfigSetting("workSemanticMatching", (value): value is number[] => Array.isArray(value) && value.every((item) => typeof item === "number"))'
          # The pi snapshot's own pi-tui entry: the only one followed by
          # photon-node. Read from the lockfile rather than spelled out, so a new
          # Kimchi patch hash on pi-tui cannot break the fixture; exactly one match
          # is required, so a layout change still fails loudly. Only the version
          # drifts.
          photon_line=$'      \x27@silvia-odwyer/photon-node\x27'
          pi_tui_line=$(awk -v tui=$'      \x27@earendil-works/pi-tui\x27: ' -v photon="$photon_line" '
            index(prev, tui) == 1 && index($0, photon) == 1 { print prev; n++ }
            { prev = $0 }
            END { if (n != 1) exit 1 }
          ' "$kimchi/pnpm-lock.yaml")
          pi_tui_version=''${pi_tui_line#*: }
          pi_tui_version=''${pi_tui_version%%(*}
          drifted_version="''${pi_tui_version%.*}.$((''${pi_tui_version##*.} + 1))"
          mutant "$kimchi" lockfile-drift pnpm-lock.yaml \
            "$pi_tui_line"$'\n'"$photon_line" \
            "''${pi_tui_line/: $pi_tui_version/: $drifted_version}"$'\n'"$photon_line"
          mutant "$kimchi" inert-consumed src/config.ts \
            'export function getAgentConfigDir(): string {' $'export function getAgentConfigDir(): string {\n\tvoid loadConfig().maxToolResultChars'
          mutant "$kimchi" project-tier src/config.ts \
            'apiKey: projectExtras.apiKey ?? globalExtras.apiKey' 'apiKey: globalExtras.apiKey'
          mutant "$pi" pi-scope-merged dist/core/settings-manager.js \
            'const value = this.globalSettings.defaultProjectTrust;' 'const value = this.settings.defaultProjectTrust;'
          # pi's own bundle repeats main.js, so every copy loses the read.
          mutant "$pi" pi-scope-unread dist/main.js \
            'getGlobalSettings().httpProxy' 'getGlobalSettings().httpProxyProbe'
          for bundled in $(grep -rlF 'getGlobalSettings().httpProxy' "$TMPDIR/pi-scope-unread-source/dist/bundle"); do
            substituteInPlace "$bundled" \
              --replace-fail 'getGlobalSettings().httpProxy' 'getGlobalSettings().httpProxyProbe'
          done
          mutant "$pi" pi-definition-reference dist/core/settings-schema.d.ts \
            '    retry?: RetrySettings;' $'    retry?: RetrySettings;\n    compaction?: import("./compaction/compaction.js").CompactionSettings;'

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
          # Exercise descriptor traversal independently: array items, nested
          # properties, and direct config keys cannot bypass runtime guards.
          while IFS=: read -r label key kind; do
            expect_rejection "$label" "$TMPDIR/$label-source" \
              "config.json validation shape changed: $key is no longer guarded as a $kind"
          done >> "$TMPDIR/proof" <<'SHAPES'
          config-array-shape:skillPaths.[]:string
          config-nested-shape:telemetry.enabled:boolean
          config-scalar-shape:llmEndpoint:string
          SHAPES
          for label in config-timezone-alias-mutable config-timezone-computed-key config-timezone-guard; do
            expect_rejection "$label" "$TMPDIR/$label-source" \
              'tui.timezone is no longer guarded as a string' >> "$TMPDIR/proof"
          done
          # Requiring a dotted argument would reject both paths. The extractor
          # checks that the helper still guards tui.timezone as a string.
          for label in config-timezone-alias-value config-timezone-bracket-literal; do
            if ! (
              ${runExtractor ''"$TMPDIR/$label-source"'' ''"$TMPDIR/$label.json"'' ''"$pi"''}
            ); then
              echo "FAIL: $label did not preserve the tui.timezone guard" >&2
              exit 1
            fi
            echo "$label (exit 0): preserved the tui.timezone string guard" >> "$TMPDIR/proof"
          done
          for label in "''${inline_rejected[@]}"; do
            expect_rejection "$label" "$TMPDIR/$label-source" \
              'is not bound to a local' >> "$TMPDIR/proof"
          done
          expect_rejection config-inline-unattributable "$TMPDIR/config-inline-unattributable-source" \
            'cannot attribute the JSON read' >> "$TMPDIR/proof"
          # A second same-named declaration in a live module makes the schema
          # ambiguous, which must stop the extraction rather than pick one.
          expect_rejection duplicate-live-schema "$TMPDIR/duplicate-live-schema-source" \
            'TypeScript declaration FermentV2Settings is declared 2 times' >> "$TMPDIR/proof"
          expect_rejection hand-shape-new-member "$TMPDIR/hand-shape-new-member-source" \
            'readTeleportCompactHintEnabled reads teleport.delayMs, which the teleport shape lacks' >> "$TMPDIR/proof"
          expect_rejection hand-shape-retyped "$TMPDIR/hand-shape-retyped-source" \
            'readSurveyConfig no longer guards surveys.*.seenAt as a string' >> "$TMPDIR/proof"
          expect_rejection helper-computed-key "$TMPDIR/helper-computed-key-source" \
            'passes a non-constant key to readConfigSetting' >> "$TMPDIR/proof"
          expect_rejection helper-guard-conflict "$TMPDIR/helper-guard-conflict-source" \
            'harness setting sessionNameModel has incompatible read guards:' >> "$TMPDIR/proof"
          expect_rejection helper-retained-conflict "$TMPDIR/helper-retained-conflict-source" \
            'harness setting fermentV2 has incompatible retained FermentV2Settings and read guard string at' >> "$TMPDIR/proof"
          expect_rejection lockfile-drift "$TMPDIR/lockfile-drift-source" \
            "Kimchi's pnpm-lock.yaml resolves pi's @earendil-works/pi-tui to \"$drifted_version\"" >> "$TMPDIR/proof"
          expect_rejection pi-scope-unread "$kimchi" \
            'pi reads Settings keys ["httpProxy"] in no way the extractor recognizes' "$TMPDIR/pi-scope-unread-source" >> "$TMPDIR/proof"
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
          # Reads without a type predicate remain visible as unknown; a typed
          # guard yields its accepted type even for a newly named key.
          for fixture in config-parse-attribution:surveys helper-unresolved-guard:semanticProbe; do
            IFS=: read -r label name <<< "$fixture"
            ${runExtractor ''"$TMPDIR/$label-source"'' ''"$TMPDIR/$label.json"'' ''"$pi"''}
            if ${pkgs.jq}/bin/jq -e --arg name "$name" \
              '.harness.keys[$name] == {optional: true, project: false, source: "kimchi", type: null}' \
              "$TMPDIR/$label.json" > /dev/null; then
              echo "$label (exit 0): emitted untyped harness read $name" >> "$TMPDIR/proof"
            else
              echo "FAIL: $label did not emit $name as an untyped harness read" >&2
              ${pkgs.jq}/bin/jq --arg name "$name" '.harness.keys[$name]' "$TMPDIR/$label.json" >&2
              exit 1
            fi
          done
          for fixture in helper-unknown-key:sessionNameModelProbe:string helper-named-guard:fermentV2Probe:object; do
            IFS=: read -r label name type <<< "$fixture"
            ${runExtractor ''"$TMPDIR/$label-source"'' ''"$TMPDIR/$label.json"'' ''"$pi"''}
            ${pkgs.jq}/bin/jq -e --arg name "$name" --arg type "$type" \
              '.harness.keys[$name] | .type == $type and .optional == true and .project == false' \
              "$TMPDIR/$label.json" > /dev/null
            echo "$label (exit 0): derived $name as $type" >> "$TMPDIR/proof"
          done
          ${runExtractor ''"$TMPDIR/helper-number-array-source"'' ''"$TMPDIR/helper-number-array.json"'' ''"$pi"''}
          ${pkgs.jq}/bin/jq -e \
            '.harness.keys.workSemanticMatching | .type == "array" and .items.type == "number"' \
            "$TMPDIR/helper-number-array.json" > /dev/null
          echo 'helper-number-array (exit 0): retained number[] items' >> "$TMPDIR/proof"
          {
            ${runExtractor ''"$TMPDIR/helper-known-unresolved-source"'' ''"$TMPDIR/helper-known-unresolved.json"'' ''"$pi"''}
          } > "$TMPDIR/helper-known-unresolved.log" 2>&1
          known_output=$(< "$TMPDIR/helper-known-unresolved.log")
          case "$known_output" in
            *'has an unresolved read guard for known harness setting fermentV2'*) ;;
            *) echo "FAIL: known unresolved helper read had no diagnostic" >&2; exit 1 ;;
          esac
          ${pkgs.jq}/bin/jq -e '.harness.keys.fermentV2.type == "object"' \
            "$TMPDIR/helper-known-unresolved.json" > /dev/null
          echo 'helper-known-unresolved (exit 0): warned and retained parser shape' >> "$TMPDIR/proof"
          # Resolve re-exported Settings through the compaction module's
          # replacement interface, whose enabled member is required.
          ${runExtractor ''"$kimchi"'' ''"$TMPDIR/pi-definition-reference.json"'' ''"$TMPDIR/pi-definition-reference-source"''}
          if ${pkgs.jq}/bin/jq -e \
            '.harness.keys.compaction.properties.enabled | .type == "boolean" and .optional == null' \
            "$TMPDIR/pi-definition-reference.json" > /dev/null; then
            echo 'pi-definition-reference (exit 0): CompactionSettings.enabled is required' >> "$TMPDIR/proof"
          else
            echo "FAIL: pi-definition-reference did not resolve CompactionSettings through Settings" >&2
            ${pkgs.jq}/bin/jq '.harness.keys.compaction' "$TMPDIR/pi-definition-reference.json" >&2
            exit 1
          fi
          # A pi key's project scope follows how pi reads it.
          ${runExtractor ''"$kimchi"'' ''"$TMPDIR/pi-scope-merged.json"'' ''"$TMPDIR/pi-scope-merged-source"''}
          if ${pkgs.jq}/bin/jq -e \
            '.harness.keys.defaultProjectTrust.project == true' \
            "$TMPDIR/pi-scope-merged.json" > /dev/null; then
            echo 'pi-scope-merged (exit 0): defaultProjectTrust project=true' >> "$TMPDIR/proof"
          else
            echo 'FAIL: pi-scope-merged did not mark defaultProjectTrust as project scoped' >&2
            ${pkgs.jq}/bin/jq '.harness.keys | map_values(.project)' "$TMPDIR/pi-scope-merged.json" >&2
            exit 1
          fi
          # Inertness is derived too: one consumer of the loaded value clears it.
          ${runExtractor ''"$TMPDIR/inert-consumed-source"'' ''"$TMPDIR/inert-consumed.json"'' ''"$pi"''}
          if ${pkgs.jq}/bin/jq -e \
            '.config.keys | has("maxToolResultChars") and (.maxToolResultChars.inert == null) and
             (.mcpSearch.inert == true) and (.mcpSearchLimit.inert == true)' \
            "$TMPDIR/inert-consumed.json" > /dev/null; then
            echo 'inert-consumed (exit 0): maxToolResultChars inert=null' >> "$TMPDIR/proof"
          else
            echo 'FAIL: inert-consumed did not derive the expected inert config keys' >&2
            ${pkgs.jq}/bin/jq '.config.keys | {maxToolResultChars, mcpSearch, mcpSearchLimit}' "$TMPDIR/inert-consumed.json" >&2
            exit 1
          fi
          {
            ${pkgs.coreutils}/bin/cat "$TMPDIR/proof"
            echo 'kimchi-extract: config.json harness guard passed'
          } > "$out"
        '';
    };
}
