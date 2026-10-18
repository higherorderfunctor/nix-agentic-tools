# Check names must not force package values. Completeness is checked by
# go-floor-declared-list against both original passthru predicates.
{
  lib,
  isLinux,
}:
{
  # Recipe-owned floors have no release-update extract chain.
  github-mcp = "recipe";
  mcp-language-server = "recipe";
  tsgolint = "recipe";

  # Sidecar-owned floors must precede vendor extraction.
  beads = "sidecar";
  "beads.dolt" = "sidecar";
  cliproxyapi = "sidecar";
  cpa-manager-plus = "sidecar";
  gh = "sidecar";
  glab = "sidecar";
  iron-proxy = "sidecar";
  kimchi = "sidecar";
  oh-my-posh = "sidecar";
  otel-tui = "sidecar";
  pipelock = "sidecar";
}
# gluetun is absent from ciPackages on Darwin.
// lib.optionalAttrs isLinux {gluetun = "sidecar";}
