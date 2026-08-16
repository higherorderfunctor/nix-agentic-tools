{runCommandLocal}:
runCommandLocal "bravo-tool" {
  passthru.facetMockOwner = "bravo";
} ''
  mkdir -p "$out"
  printf '%s\n' bravo > "$out/marker"
''
