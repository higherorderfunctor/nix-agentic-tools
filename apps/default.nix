# Nix apps: generate, update, check-drift, check-health.
# Implementation in Phases 0.3 (generate) and 4 (others).
{
  lib,
  pkgs,
  self,
}: {
  # generate — fragment → instruction file generation
  # update — MCP server version updates
  # check-drift — MCP tool drift detection
  # check-health — MCP server health checks
}
