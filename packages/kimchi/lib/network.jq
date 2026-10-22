# NetworkCallSites.json from runQueries (every result set, tuples sorted)
# into the `network` fact:
#
#   {callSites: [{readBy, file, line, library, bundledModule,
#                 targets: [{kind, value, host, origin}]}],
#    unattributed: [{readBy, file, line, value, host}]}
#
# readBy is kimchi or pi, from the path under the database's source root;
# file and origin are relative to Kimchi's tree or to its node_modules. A
# target's kind is url (a literal with a scheme), host (a scheme-less host
# literal), env (value is the variable's name), argument or property (no
# literal or variable reaches the target; value is the parameter's or the
# property's name) or dynamic (value is the target's text). Every array is
# sorted, so the output is a function of the result sets alone.
def located:
  if startswith("kimchi/node_modules/") then {readBy: "pi", file: ltrimstr("kimchi/node_modules/")}
  elif startswith("kimchi/") then {readBy: "kimchi", file: ltrimstr("kimchi/")}
  else error("network: \(.) is outside the kimchi source root")
  end;
def host:
  capture("^[A-Za-z][A-Za-z0-9+.-]*://([^/?#@]*@)?(?<host>\\[[^\\]/?#@]*\\]|[^\\[\\]/?#:@]+)(?=[:/?#]|$)")
  | .host
  | ascii_downcase;

.["#select"].tuples as $select
| if ($select | length) == 0 then error("network: NetworkCallSites found no call site") else . end
| {
    callSites: (
      $select
      | group_by([.[0], .[1], .[2], .[7]])
      | map(.[0] as [$file, $line, $library, $_, $_, $_, $_, $bundled]
        | ($file | located) + {
            line: $line,
            library: $library,
            bundledModule: (if $bundled == "" then null else $bundled end),
            targets: (
              map(.[3] as $kind | {
                kind: $kind,
                value: .[4],
                host: (if $kind == "url" then ((.[4] | host) // null)
                       elif $kind == "host" then (.[4] | sub(":[0-9]+$"; "") | ascii_downcase)
                       else null end),
                origin: "\(.[5] | located | .file):\(.[6])"
              })
              | unique
            )
          })
      | sort_by([.readBy, .file, .line, .library, .bundledModule])
    ),
    unattributed: (
      .unattributed.tuples
      | map(. as [$value, $file, $line]
        | ($file | located) + {line: $line, value: $value, host: (($value | host) // null)})
      | unique
      | sort_by([.readBy, .file, .line, .value])
    )
  }
