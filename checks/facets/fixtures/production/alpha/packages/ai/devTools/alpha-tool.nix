{
  ancestor-tool,
  runCommandLocal,
  sibling_tool,
}:
runCommandLocal "facet-alpha-tool" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  diff -u --label "expected ancestor marker" --label "ancestor scope dependency" \
    <(printf '%s\n' ancestor) "${ancestor-tool}/passed"
  diff -u --label "expected sibling marker" --label "sibling scope dependency" \
    <(printf '%s\n' sibling) "${sibling_tool}/passed"
  mkdir -p "$out"
  touch "$out/passed"
''
