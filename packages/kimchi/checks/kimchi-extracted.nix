# Drift and collision checks for Kimchi's two source-derived settings surfaces.
# cspell:ignore odwyer
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (import ../../../lib/extracted {inherit pkgs;}) mkDriftCheck;
    package = self.ciPackages.${system}.kimchi;
    inherit (package.passthru) extracted extractionSources extractionSourceUrls;
    committed = ../extracted.json;
    extractor = ../extract/extract.mjs;
    configFixtureVersion =
      if pkgs.lib.versionAtLeast package.version "1.5.0"
      then package.version
      else "1.5.0";
    configFixtureAnnotationFilter = ''
      def version: split(".") | map(tonumber);
      def deactivate_after($pinned):
        with_entries(
          .value |= if .introduced and (.introduced | version) > ($pinned | version)
                    then .introduced = "99.0.0"
                    else .
                    end
        );
      .environment |= deactivate_after("${package.version}") |
      .environmentIgnored |= deactivate_after("${package.version}")
    '';

    runExtractorForVersion = version: annotations: source: output: pi: let
      sourceUrl = builtins.replaceStrings [package.version] [version] extractionSourceUrls.kimchi;
    in ''
      ${pkgs.yq-go}/bin/yq -o=json '.' ${source}/pnpm-lock.yaml > "$TMPDIR/kimchi-lock.json"
      ${pkgs.nodejs}/bin/node ${extractor} \
        --annotations ${annotations} \
        --kimchi-lock "$TMPDIR/kimchi-lock.json" \
        --kimchi-source ${source} \
        --kimchi-source-url ${pkgs.lib.escapeShellArg sourceUrl} \
        --kimchi-version ${pkgs.lib.escapeShellArg version} \
        --out ${output} \
        --pi-agent-core-package ${extractionSources.piAgentCore} \
        --pi-ai-package ${extractionSources.piAi} \
        --pi-package ${pi} \
        --pi-tui-package ${extractionSources.piTui} \
        --typescript ${pkgs.typescript_5}/lib/node_modules/typescript/lib/typescript.js
    '';
    runExtractorWithAnnotations = runExtractorForVersion package.version;
    runExtractor = runExtractorWithAnnotations ../extract/annotations.json;
  in {
    kimchi-extracted = mkDriftCheck {
      inherit committed extracted;
      name = "kimchi";
      sidecar = "packages/kimchi/extracted.json";
    };

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

        jq=${pkgs.jq}/bin/jq
        "$jq" '.config.FUTURE_BAD = {introduced: "99.0.0", bogus: true}' \
          ${../extract/annotations.json} > "$TMPDIR/future-config-unknown-key.json"
        "$jq" '${configFixtureAnnotationFilter}' \
          ${../extract/annotations.json} > "$TMPDIR/config-introduced-annotations.json"
        "$jq" '.environment.FUTURE_BAD = {introduced: "99.0.0"}' \
          ${../extract/annotations.json} > "$TMPDIR/future-environment-missing-controls.json"
        "$jq" '.environment.FUTURE_BAD = {controls: "future", introduced: "99.0.0", bogus: true}' \
          ${../extract/annotations.json} > "$TMPDIR/future-environment-unknown-key.json"
        "$jq" '.environmentIgnored.futureBad = {names: ["FUTURE_BAD"], reason: "future", introduced: "99.0.0", bogus: true}' \
          ${../extract/annotations.json} > "$TMPDIR/future-ignored-unknown-key.json"
        "$jq" '.environmentIgnored.futureBad = {names: [123], reason: "future", introduced: "99.0.0"}' \
          ${../extract/annotations.json} > "$TMPDIR/future-ignored-numeric-name.json"
        "$jq" '.environmentIgnored.futureBad = {names: ["FUTURE_BAD"], reason: true, introduced: "99.0.0"}' \
          ${../extract/annotations.json} > "$TMPDIR/future-ignored-boolean-reason.json"
        "$jq" '.environmentIgnored.futureBad = {names: [], reason: "future", introduced: "99.0.0"}' \
          ${../extract/annotations.json} > "$TMPDIR/future-ignored-empty-names.json"
        "$jq" '.environmentIgnored.futureBad = {names: [" "], reason: "future", introduced: "99.0.0"}' \
          ${../extract/annotations.json} > "$TMPDIR/future-ignored-blank-name.json"
        "$jq" '.environmentIgnored.futureBad = {names: ["FUTURE_BAD"], reason: " ", introduced: "99.0.0"}' \
          ${../extract/annotations.json} > "$TMPDIR/future-ignored-blank-reason.json"

        mutant "$kimchi" collision src/config.ts \
          'const parsed = JSON.parse(raw)' $'const parsed = JSON.parse(raw)\n\t\tvoid parsed.harness'
        mutant "$kimchi" config-array-shape src/config.ts \
          'typeof p === "string"' 'typeof p === "number"'
        mutant "$kimchi" config-nested-shape src/config.ts \
          'typeof t.enabled === "boolean"' 'typeof t.enabled === "string"'
        # Repoint readSurveyConfig's config.json parse: at the harness file its
        # `surveys` read must surface as an unknown harness key, and at a file
        # that is neither surface the parse must be unattributable.
        survey_parse=$'function readSurveyConfig(surveyId: string, configPath: string): SurveyConfig | undefined {\n\ttry {\n\t\tconst parsed = JSON.parse(readFileSync('
        mutant "$kimchi" config-parse-attribution src/config.ts \
          "''${survey_parse}configPath, \"utf-8\"))" \
          "''${survey_parse}resolve(AGENT_CONFIG_DIR, \"settings.json\"), \"utf-8\"))"
        mutant "$kimchi" config-parse-unattributable src/config.ts \
          "''${survey_parse}configPath, \"utf-8\"))" \
          "''${survey_parse}resolve(AGENT_CONFIG_DIR, \"state.json\"), \"utf-8\"))"
        mutant "$kimchi" config-shape src/config.ts \
          'typeof parsed.apiKey === "string"' 'typeof parsed.apiKey === "number"'
        mutant "$kimchi" config-second-shape src/config.ts \
          'typeof parsed.llmEndpoint === "string"' 'typeof parsed.llmEndpoint === "number"'
        cp -r "$kimchi" "$TMPDIR/config-introduced-source"
        chmod -R u+w "$TMPDIR/config-introduced-source"
        config_introduced="$TMPDIR/config-introduced-source/src/config.ts"
        if ! grep -qF $'\ttui?: TuiConfig' "$config_introduced"; then
          substituteInPlace "$config_introduced" \
          --replace-fail \
            'export type MigrationState = "done" | "skip-forever"' \
            $'export type MigrationState = "done" | "skip-forever"\n\nexport interface TuiConfig {\n\t/** Wheel-scroll step (lines) for fullscreen (alt-screen) mode. Min 1; floored by the pi-tui clamp. */\n\twheelScrollLines?: number\n}' \
          --replace-fail \
            $'\tmemoryExtraction?: { model?: string }' \
            $'\tmemoryExtraction?: { model?: string }\n\ttui?: TuiConfig' \
          --replace-fail \
            $'\t\tconst mx = parsed.memoryExtraction\n\t\tif (mx && typeof mx === "object" && typeof mx.model === "string" && mx.model.length > 0) {\n\t\t\tmemoryExtraction = { model: mx.model }\n\t\t}\n\n\t\treturn {' \
            $'\t\tconst mx = parsed.memoryExtraction\n\t\tif (mx && typeof mx === "object" && typeof mx.model === "string" && mx.model.length > 0) {\n\t\t\tmemoryExtraction = { model: mx.model }\n\t\t}\n\n\t\tlet tui: TuiConfig | undefined\n\t\tconst tc = parsed.tui\n\t\tif (tc && typeof tc === "object" && typeof tc.wheelScrollLines === "number") {\n\t\t\ttui = { wheelScrollLines: tc.wheelScrollLines }\n\t\t}\n\n\t\treturn {' \
          --replace-fail \
            $'\t\t\tmemoryExtraction,\n\t\t}' \
            $'\t\t\tmemoryExtraction,\n\t\t\ttui,\n\t\t}' \
          --replace-fail \
            $'\t\tmemoryExtraction: projectExtras.memoryExtraction ?? globalExtras.memoryExtraction,\n\t}' \
            $'\t\tmemoryExtraction: projectExtras.memoryExtraction ?? globalExtras.memoryExtraction,\n\t\ttui: projectExtras.tui ?? globalExtras.tui,\n\t}' \
          --replace-fail \
            $'\t\tmemoryExtraction: extras.memoryExtraction,\n\t}' \
            $'\t\tmemoryExtraction: extras.memoryExtraction,\n\t\ttui: extras.tui,\n\t}'
        fi
        mutant "$kimchi" duplicate-live-schema src/agent-discovery/agents/claude-code.ts \
          'import { homedir } from "node:os"' $'import "../../extensions/model-catalog/model-metadata.js"\nimport { homedir } from "node:os"'
        mutant "$kimchi" entry-imported-read src/auxiliary-files/resolver.ts \
          'if (env.XDG_DATA_HOME) {' 'if (env.XDG_DATA_HOME && !process.env.KIMCHI_CODING_AGENT_DIR) {'
        mutant "$kimchi" entry-late-write src/entry.ts \
          'installPasteInterceptor()' $'installPasteInterceptor()\nprocess.env.KIMCHI_NO_UPDATE_CHECK = "1"'
        mutant "$kimchi" entry-overwrite src/entry.ts \
          'process.env.KIMCHI_DISABLE_BUILTIN_PROVIDERS = "1"' $'process.env.KIMCHI_DISABLE_BUILTIN_PROVIDERS = "1"\nprocess.env.KIMCHI_NO_UPDATE_CHECK = "0"'
        mutant "$kimchi" entry-unread src/entry.ts \
          'const inheritedPiAgentDir = process.env.PI_CODING_AGENT_DIR' 'const inheritedPiAgentDir = undefined'
        mutant "$kimchi" hand-shape-new-member src/config.ts \
          '		const enabled = parsed?.teleport?.compactHint?.enabled' $'\t\tif (typeof parsed?.teleport?.delayMs === "number") return false\n\t\tconst enabled = parsed?.teleport?.compactHint?.enabled'
        mutant "$kimchi" hand-shape-retyped src/config.ts \
          'return typeof seenAt === "string" && seenAt.length > 0' 'return typeof seenAt === "number"'
        mutant "$kimchi" helper-computed-key src/extensions/multi-model.ts \
          'readConfigSetting("multiModel"' 'readConfigSetting(String(Date.now())'
        mutant "$kimchi" helper-unknown-key src/extensions/tags.ts \
          'readConfigSetting("hidePhaseChanges"' 'readConfigSetting("hidePhaseChangesProbe"'
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
        mutant "$kimchi" environment-app-name package.json \
          '"name": "kimchi"' '"name": "tau"'
        mutant "$kimchi" environment-stale-ignore src/agent-discovery/agents/opencode.ts \
          'const envOverride = process.env.OPENCODE_CONFIG' 'const envOverride = undefined'
        mutant "$kimchi" environment-unlisted src/extensions/skills-manager/skill-manager.ts \
          'process.env.SKILLS_DIR ??' 'process.env.SKILLS_DIR ?? process.env.UNLISTED_PROBE_DIR ??'
        cp -r "$kimchi" "$TMPDIR/environment-patch-alias-source"
        chmod -R u+w "$TMPDIR/environment-patch-alias-source"
        printf '%s\n' \
          '+++ b/dist/environment-probe.js' \
          '+const environment = process.env' \
          '+void environment.UNLISTED_PATCH_PROBE' \
          > "$TMPDIR/environment-patch-alias-source/patches/environment-probe.patch"
        mutant "$kimchi" harness-shape src/extensions/orchestration/model-roles.ts \
          'orchestrator: string' 'orchestrator: number'
        mutant "$kimchi" project-tier src/config.ts \
          'apiKey: projectExtras.apiKey ?? globalExtras.apiKey' 'apiKey: globalExtras.apiKey'
        mutant "$pi" pi-app-name dist/config.js \
          'export const APP_NAME = piConfigName || "pi";' 'export const APP_NAME = "pi";'
        mutant "$pi" pi-scope-merged dist/core/settings-manager.js \
          'const value = this.globalSettings.defaultProjectTrust;' 'const value = this.settings.defaultProjectTrust;'
        # pi's own bundle repeats main.js, so every copy loses the read.
        mutant "$pi" pi-scope-unread dist/main.js \
          'getGlobalSettings().httpProxy' 'getGlobalSettings().httpProxyProbe'
        for bundled in $(grep -rlF 'getGlobalSettings().httpProxy' "$TMPDIR/pi-scope-unread-source/dist/bundle"); do
          substituteInPlace "$bundled" \
            --replace-fail 'getGlobalSettings().httpProxy' 'getGlobalSettings().httpProxyProbe'
        done
        mutant "$pi" pi-definition-collision dist/core/settings-manager.d.ts \
          '    compaction?: CompactionSettings;' $'    compaction?: CompactionSettings;\n    compactionProbe?: import("./compaction/compaction.js").CompactionSettings;'
        mutant "$pi" pi-definition-reference dist/core/settings-manager.d.ts \
          '    compaction?: CompactionSettings;' '    compaction?: import("./compaction/compaction.js").CompactionSettings;'

        expect_rejection() {
          label="$1"
          source="$2"
          expected="$3"
          pi_source="''${4:-$pi}"
          annotations="''${5:-${../extract/annotations.json}}"
          if rejected_output=$(
            {
              ${runExtractorWithAnnotations ''"$annotations"'' "$source" ''"$TMPDIR/$label.json"'' ''"$pi_source"''}
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
          'that are neither pi Settings nor Kimchi additions: ["surveys"]' >> "$TMPDIR/proof"
        expect_rejection config-parse-unattributable "$TMPDIR/config-parse-unattributable-source" \
          'cannot attribute the JSON read' >> "$TMPDIR/proof"
        expect_rejection config-shape "$TMPDIR/config-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection config-second-shape "$TMPDIR/config-second-shape-source" \
          "config.json validation shape changed" >> "$TMPDIR/proof"
        expect_rejection future-config-unknown-key "$kimchi" \
          'config.FUTURE_BAD has unknown keys: ["bogus"]' "$pi" \
          "$TMPDIR/future-config-unknown-key.json" >> "$TMPDIR/proof"
        # A dead copy of a schema is invisible; importing it makes two live
        # ones, which must stop the extraction rather than pick one.
        expect_rejection duplicate-live-schema "$TMPDIR/duplicate-live-schema-source" \
          'TypeScript declaration ModelCustomMetadataSchema is declared 2 times' >> "$TMPDIR/proof"
        expect_rejection pi-definition-collision "$kimchi" \
          'two different interfaces named CompactionSettings' "$TMPDIR/pi-definition-collision-source" >> "$TMPDIR/proof"
        expect_rejection hand-shape-new-member "$TMPDIR/hand-shape-new-member-source" \
          'readTeleportCompactHintEnabled reads teleport.delayMs, which the teleport shape lacks' >> "$TMPDIR/proof"
        expect_rejection hand-shape-retyped "$TMPDIR/hand-shape-retyped-source" \
          'readSurveyConfig no longer guards surveys.*.seenAt as a string' >> "$TMPDIR/proof"
        expect_rejection helper-computed-key "$TMPDIR/helper-computed-key-source" \
          'passes a non-constant key to readConfigSetting' >> "$TMPDIR/proof"
        expect_rejection helper-unknown-key "$TMPDIR/helper-unknown-key-source" \
          'that are neither pi Settings nor Kimchi additions: ["hidePhaseChangesProbe"]' >> "$TMPDIR/proof"
        expect_rejection lockfile-drift "$TMPDIR/lockfile-drift-source" \
          "Kimchi's pnpm-lock.yaml resolves pi's @earendil-works/pi-tui to \"$drifted_version\"" >> "$TMPDIR/proof"
        expect_rejection pi-scope-unread "$kimchi" \
          'pi reads Settings keys ["httpProxy"] in no way the extractor recognizes' "$TMPDIR/pi-scope-unread-source" >> "$TMPDIR/proof"
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
        expect_rejection environment-patch-alias "$TMPDIR/environment-patch-alias-source" \
          'environment census changed; new=["UNLISTED_PATCH_PROBE"]' >> "$TMPDIR/proof"
        expect_rejection future-environment-missing-controls "$kimchi" \
          "environment.FUTURE_BAD needs a non-empty 'controls' description" "$pi" \
          "$TMPDIR/future-environment-missing-controls.json" >> "$TMPDIR/proof"
        expect_rejection future-environment-unknown-key "$kimchi" \
          'environment.FUTURE_BAD has unknown keys: ["bogus"]' "$pi" \
          "$TMPDIR/future-environment-unknown-key.json" >> "$TMPDIR/proof"
        expect_rejection future-ignored-unknown-key "$kimchi" \
          'environmentIgnored.futureBad has unknown keys: ["bogus"]' "$pi" \
          "$TMPDIR/future-ignored-unknown-key.json" >> "$TMPDIR/proof"
        expect_rejection future-ignored-numeric-name "$kimchi" \
          'environmentIgnored.futureBad needs a non-empty names list of non-empty strings' "$pi" \
          "$TMPDIR/future-ignored-numeric-name.json" >> "$TMPDIR/proof"
        expect_rejection future-ignored-boolean-reason "$kimchi" \
          'environmentIgnored.futureBad needs a non-empty string reason' "$pi" \
          "$TMPDIR/future-ignored-boolean-reason.json" >> "$TMPDIR/proof"
        expect_rejection future-ignored-empty-names "$kimchi" \
          'environmentIgnored.futureBad needs a non-empty names list of non-empty strings' "$pi" \
          "$TMPDIR/future-ignored-empty-names.json" >> "$TMPDIR/proof"
        expect_rejection future-ignored-blank-name "$kimchi" \
          'environmentIgnored.futureBad needs a non-empty names list of non-empty strings' "$pi" \
          "$TMPDIR/future-ignored-blank-name.json" >> "$TMPDIR/proof"
        expect_rejection future-ignored-blank-reason "$kimchi" \
          'environmentIgnored.futureBad needs a non-empty string reason' "$pi" \
          "$TMPDIR/future-ignored-blank-reason.json" >> "$TMPDIR/proof"
        expect_rejection harness-shape "$TMPDIR/harness-shape-source" \
          "harness/settings.json Kimchi additions validation shape changed" >> "$TMPDIR/proof"
        expect_rejection pi-app-name "$kimchi" \
          'pi APP_NAME in' "$TMPDIR/pi-app-name-source" >> "$TMPDIR/proof"

        ${runExtractor ''"$kimchi"'' ''"$TMPDIR/real.json"'' ''"$pi"''}
        ${runExtractorForVersion configFixtureVersion ''"$TMPDIR/config-introduced-annotations.json"'' ''"$TMPDIR/config-introduced-source"'' ''"$TMPDIR/config-introduced.json"'' ''"$pi"''}
        if "$jq" -e \
          '.config.keys.tui == {
             typeExpression: "TuiConfig",
             type: "object",
             properties: {
               wheelScrollLines: {
                 typeExpression: "number",
                 type: "number",
                 optional: true,
                 description: "Wheel-scroll step (lines) for fullscreen (alt-screen) mode. Min 1; floored by the pi-tui clamp."
               }
             },
             optional: true,
             project: true
           } and
           (.config.keys.tui | has("introduced") | not)' \
          "$TMPDIR/config-introduced.json" > /dev/null; then
          echo "config-introduced (exit 0): tui.wheelScrollLines activated without annotation metadata" >> "$TMPDIR/proof"
        else
          echo "FAIL: introduced config annotation did not emit the expected descriptor" >&2
          "$jq" '.config.keys.tui' "$TMPDIR/config-introduced.json" >&2
          exit 1
        fi
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
        # Settings definitions follow the interface Settings references, not
        # the first interface of that name: pi's compaction.d.ts declares an
        # all-required CompactionSettings next to settings-manager's.
        ${runExtractor ''"$kimchi"'' ''"$TMPDIR/pi-definition-reference.json"'' ''"$TMPDIR/pi-definition-reference-source"''}
        for fixture in real:true pi-definition-reference:null; do
          IFS=: read -r label optional <<< "$fixture"
          if ${pkgs.jq}/bin/jq -e --argjson optional "$optional" \
            '.harness.definitions.CompactionSettings.enabled.optional == $optional' \
            "$TMPDIR/$label.json" > /dev/null; then
            echo "$label (exit 0): CompactionSettings.enabled optional=$optional" >> "$TMPDIR/proof"
          else
            echo "FAIL: $label did not resolve CompactionSettings through Settings" >&2
            ${pkgs.jq}/bin/jq '.harness.definitions.CompactionSettings' "$TMPDIR/$label.json" >&2
            exit 1
          fi
        done
        # A pi key's project scope follows how pi reads it.
        ${runExtractor ''"$kimchi"'' ''"$TMPDIR/pi-scope-merged.json"'' ''"$TMPDIR/pi-scope-merged-source"''}
        for fixture in real:false pi-scope-merged:true; do
          IFS=: read -r label project <<< "$fixture"
          if ${pkgs.jq}/bin/jq -e --argjson project "$project" \
            '.harness.keys | (.defaultProjectTrust.project == $project) and (.httpProxy.project == false) and (.theme.project == true)' \
            "$TMPDIR/$label.json" > /dev/null; then
            echo "$label (exit 0): defaultProjectTrust project=$project" >> "$TMPDIR/proof"
          else
            echo "FAIL: $label did not derive the expected harness key scopes" >&2
            ${pkgs.jq}/bin/jq '.harness.keys | map_values(.project)' "$TMPDIR/$label.json" >&2
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
