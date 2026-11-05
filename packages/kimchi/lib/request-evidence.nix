# Additional facts from the same pack, models, result derivation and release database as network.
{
  codeql,
  network,
  pkgs,
}: let
  factsOf = name: on: let
    results = network.resultsOf name on;
  in
    pkgs.runCommand "kimchi-codeql-${name}-request-evidence" {nativeBuildInputs = [pkgs.jq];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      jq -S '[.["#select"].tuples[] | . as [$id, $enabled, $restart, $file, $line] |
        def booleanValue: if . == "absent" then null elif . == "unresolved" then . else fromjson end;
        {id: $id, defaultEnabled: ($enabled | booleanValue), restartRequired: ($restart | booleanValue),
         file: $file, line: $line}] | sort_by([.id, .file, .line])' \
        ${results}/ResourceDefinitions.json > "$out/resourceDefinitions.json"
      jq -S '{
        defaultRegion: [.defaultRegion.tuples[] | . as [$value, $file, $line] | {value: $value, file: $file, line: $line}] | sort,
        fields: [.["#select"].tuples[] | . as [$region, $field, $value, $file, $line] |
          {region: $region, field: $field, value: $value, file: $file, line: $line}] | sort_by([.region, .field, .file, .line])
      }' ${results}/RegionRegistry.json > "$out/regionRegistry.json"
      jq -S '[.["#select"].tuples[] |
        . as [$file, $line, $column, $library, $guardFile, $guardLine, $guardColumn, $kind, $key, $outcome, $conditionOutcome, $scope, $bundled] |
        {callSite: {file: $file, line: $line, column: $column, library: $library, bundledModule: (if $bundled == "" then null else $bundled end)},
         guardSite: {file: $guardFile, line: $guardLine, column: $guardColumn},
         sourceKind: $kind, key: $key, outcome: $outcome, conditionOutcome: ($conditionOutcome | fromjson), scope: $scope}]
        | unique | sort_by([.callSite.file, .callSite.line, .callSite.column, .callSite.library, .callSite.bundledModule, .guardSite.line, .guardSite.column, .sourceKind, .key, .outcome, .conditionOutcome])' \
        ${results}/RequestGuards.json > "$out/requestGuards.json"
      jq -S -f ${./request-callers.jq} ${results}/RequestCallers.json > "$out/requestCallers.json"
      # A renamed or moved definitions or registry export matches nothing;
      # fail rather than record an empty inventory. Guards may be empty.
      jq -e 'length > 0' "$out/resourceDefinitions.json" >/dev/null ||
        { echo "kimchi-codeql-${name}: no resource definitions found; check the STATIC_RESOURCE_DEFINITIONS export in src/resources/definitions.ts and packages/kimchi/ql/network/ResourceDefinitions.ql" >&2; exit 1; }
      jq -e '(.fields | length > 0) and (.defaultRegion | length > 0)' "$out/regionRegistry.json" >/dev/null ||
        { echo "kimchi-codeql-${name}: no region fields or default region found; check the REGIONS and DEFAULT_REGION exports in src/regions.ts and packages/kimchi/ql/network/RegionRegistry.ql" >&2; exit 1; }
    '';
in {
  inherit factsOf;
  facts = factsOf "network" codeql.database;
}
