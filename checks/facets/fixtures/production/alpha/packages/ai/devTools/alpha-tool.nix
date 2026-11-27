{
  ancestor-tool,
  sibling_tool,
  runCommandLocal,
}:
runCommandLocal "facet-alpha-tool" {nativeBuildInputs = [ancestor-tool sibling_tool];} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  test "$(cat ${ancestor-tool}/passed)" = ancestor
  test "$(cat ${sibling_tool}/passed)" = sibling
  mkdir -p "$out"
  touch "$out/passed"
''
