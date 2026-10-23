# The `environment` surface of extracted.json from the decoded result sets of
# the ../ql/environment pack:
#
#   jq -S -n -f environment.jq \
#     --slurpfile reads EnvironmentReads.json \
#     --slurpfile overwrites LaunchOverwrites.json \
#     --slurpfile annotations annotations.json
#
# A "fail" row fails the transform unless it names a reviewed unresolved
# computed read. A review with no unresolved row fails as stale.
# The one array, readBy, is sorted here; object key order is left to `jq -S`,
# the code-unit order the committed file has always had.
def tuples: .[0]["#select"].tuples;
($reads | tuples) as $reads
| ($overwrites | tuples) as $overwrites
| ([$reads[], $overwrites[]] | map(select(.[0] == "fail"))) as $fails
| "unresolved computed environment read: " as $prefix
| ($annotations[0].environmentUnresolved // {}) as $accepted
| ($fails | map(select(.[1] | startswith($prefix)) | .[1] | ltrimstr($prefix)) | unique) as $unresolved
| ($accepted | keys - $unresolved) as $stale
| if ($stale | length) > 0
  then error("kimchi-codeql-environment: stale environmentUnresolved rows; delete the stale row: " + ($stale | join("; ")))
  else . end
| ($accepted | to_entries | map(select(.value.reason | test("\\S") | not) | .key)) as $invalid
| if ($invalid | length) > 0
  then error("kimchi-codeql-environment: environmentUnresolved rows need a non-blank reason: " + ($invalid | join("; ")))
  else . end
| ($accepted | to_entries | map(. as $entry | ($fails | map(select(.[1] == ($prefix + $entry.key))) | length) as $actual | select($actual != .value.sites) | .key + " (expected " + (.value.sites | tostring) + " unresolved sites, got " + ($actual | tostring) + ")")) as $changed
| if ($changed | length) > 0
  then error("kimchi-codeql-environment: unresolved site count changed; review the row: " + ($changed | join("; ")))
  else . end
| ($fails | map(select(.[1] as $message | ($message | startswith($prefix) | not) or ($accepted | has($message | ltrimstr($prefix)) | not)))) as $fails
| if ($fails | length) > 0
  then error("kimchi-codeql-environment: " + ($fails | map(.[1] + " (" + .[-1] + ")") | unique | join("; ")))
  else . end
| ($overwrites | map(select(.[0] == "fixed") | .[1]) | unique) as $fixed
| {
    variables: (
      $reads
      | map(select(.[0] == "read"))
      | group_by(.[1])
      | map(
          (.[0][1]) as $name
          | ($fixed | index($name) != null) as $isFixed
          | {
              key: $name,
              value: (
                {
                  consumerOverridable: ($isFixed | not),
                  readBy: (map(.[2]) | unique),
                  type: "string"
                }
                + if $isFixed
                  then {reason: "src/entry.ts assigns it on every launch before anything reads it"}
                  else {} end
              )
            }
        )
      | from_entries
    )
  }
