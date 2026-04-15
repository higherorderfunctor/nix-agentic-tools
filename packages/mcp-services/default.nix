# Per-package barrel for mcp-services.
#
# This is a "virtual" package — no derivation, no overlay. It exists
# solely to contribute an HM module that provides the
# `services.mcp-servers` option tree (per-server enable/settings/
# credentials/service, mcpConfig output, tools registry, systemd
# user services). Picked up by collectFacet ["modules" "homeManager"].
{
  modules.homeManager = ./modules/homeManager/default.nix;
}
