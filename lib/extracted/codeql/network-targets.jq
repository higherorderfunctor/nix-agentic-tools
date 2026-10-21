# NetworkTargets.ql's decoded result set, {columns, tuples}, as
# {hosts: {<host>: [files]}, otherTargets: {<url>: [files]}}.
#
# A host is the authority's: a bracketed IPv6 literal kept whole, or a name
# up to a port, path, query or fragment. A URL with no such host (`file:///`,
# an unterminated bracket) stays whole under otherTargets, so nothing the query
# found is dropped. An empty result set fails: it means the query or the
# extraction found nothing, not that the program makes no requests.
def host:
  capture("^[A-Za-z][A-Za-z0-9+.-]*://([^/?#@]*@)?(?<host>\\[[^\\]/?#@]*\\]|[^\\[\\]/?#:@]+)(?=[:/?#]|$)")
  | .host
  | ascii_downcase;
def files(key):
  group_by(key) | map({key: (.[0] | key), value: (map(.file) | unique)}) | from_entries;

.tuples
| if length == 0 then error("NetworkTargets found no client request with a constant URL") else . end
| map({url: .[0], file: .[1]} | .host = ((.url | host) // null))
| {
    hosts: (map(select(.host != null)) | files(.host)),
    otherTargets: (map(select(.host == null)) | files(.url))
  }
