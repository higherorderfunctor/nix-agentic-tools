# Cases for lib/extracted/codeql/network-targets.jq, the projection of
# NetworkTargets.ql's decoded result set. jq alone, no CodeQL: the bundle's
# terms forbid distributing it, and this check is published like any other.
# Each case names its input and the key it must land under.
{pkgs, ...}: let
  projection = ../../lib/extracted/codeql/network-targets.jq;
  decoded = tuples: builtins.toFile "decoded.json" (builtins.toJSON {inherit tuples;});
  cases = decoded [
    # A name is lowercased, and userinfo and a port are not part of it.
    ["https://Example.com/api" "src/name.ts"]
    ["https://user:pw@example.com:8443/x" "src/userinfo.ts"]
    # A bracketed IPv6 literal is the host whole, with or without a port.
    ["https://[::1]:8443/api" "src/ipv6.ts"]
    ["http://[2001:DB8::1]/" "src/ipv6.ts"]
    # No host to key on: kept whole, never dropped.
    ["file:///tmp/test" "src/no-host.ts"]
    ["http:///path" "src/no-host.ts"]
    ["http://[::1" "src/no-host.ts"]
  ];
  expected = builtins.toFile "expected.json" (builtins.toJSON {
    hosts = {
      "[2001:db8::1]" = ["src/ipv6.ts"];
      "[::1]" = ["src/ipv6.ts"];
      "example.com" = ["src/name.ts" "src/userinfo.ts"];
    };
    otherTargets = {
      "file:///tmp/test" = ["src/no-host.ts"];
      "http:///path" = ["src/no-host.ts"];
      "http://[::1" = ["src/no-host.ts"];
    };
  });
in {
  checks.extracted-codeql-projection = pkgs.runCommand "extracted-codeql-projection" {nativeBuildInputs = [pkgs.jq];} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    jq --sort-keys --from-file ${projection} ${cases} > actual.json
    jq --sort-keys . ${expected} > expected.json
    diff -u expected.json actual.json
    # An empty result set is a failed extraction, not an empty inventory.
    if jq --from-file ${projection} ${decoded []} 2> empty.err; then
      echo "an empty result set projected instead of failing" >&2
      exit 1
    fi
    grep -F 'found no client request' empty.err
    touch "$out"
  '';
}
