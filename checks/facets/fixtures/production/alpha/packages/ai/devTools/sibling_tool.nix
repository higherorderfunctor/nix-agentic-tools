{runCommandLocal}:
runCommandLocal "facet-sibling" {} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  mkdir -p "$out"
  printf '%s\n' 'sibling' > "$out/passed"
''
