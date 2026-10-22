# The Go packages whose go.mod floor the go-floor checks guard, as a table
# so that listing check names never evaluates a package. Each value is the
# package's expected `passthru.fixGoFloor.goFloorDestination`: "recipe" for a
# rev-pinned package whose floor is a literal in its recipe, "sidecar" for a
# release-pinned package whose floor lives in its sources.json. The table
# carries no platform knowledge: each consumer keeps the rows present in the
# system's package set (gluetun's platforms.nix limits it to x86_64-linux), and
# go-floor-declared-list fails when the rows differ from what the two
# passthru predicates discover on that system.
{
  # Recipe-owned floors have no release-update extract chain.
  github-mcp = "recipe";
  mcp-language-server = "recipe";
  tsgolint = "recipe";

  # Sidecar-owned floors must precede vendor extraction.
  beads = "sidecar";
  "beads.dolt" = "sidecar";
  cliproxyapi = "sidecar";
  cpa-gate = "sidecar";
  cpa-manager-plus = "sidecar";
  gh = "sidecar";
  gluetun = "sidecar";
  glab = "sidecar";
  iron-proxy = "sidecar";
  kimchi = "sidecar";
  oh-my-posh = "sidecar";
  otel-tui = "sidecar";
  pipelock = "sidecar";
}
