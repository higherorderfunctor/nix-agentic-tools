# The `environment` surface of extracted.json from the decoded result sets of
# the ../ql/environment pack:
#
#   jq -S -n -f environment.jq \
#     --slurpfile reads EnvironmentReads.json \
#     --slurpfile overwrites LaunchOverwrites.json
#
# A "fail" row in either set fails the transform with every row's message.
# The one array, readBy, is sorted here; object key order is left to `jq -S`,
# the code-unit order the committed file has always had.
def tuples: .[0]["#select"].tuples;
($reads | tuples) as $reads
| ($overwrites | tuples) as $overwrites
| ([$reads[], $overwrites[]] | map(select(.[0] == "fail"))) as $fails
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
