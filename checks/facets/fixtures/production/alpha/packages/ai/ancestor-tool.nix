{runCommandLocal}:
runCommandLocal "facet-ancestor" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  mkdir -p "$out"
  printf '%s\n' 'ancestor' > "$out/passed"
''
