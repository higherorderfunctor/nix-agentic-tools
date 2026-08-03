# Semble ships its CLI and MCP entry point in one derivation. Re-point
# mainProgram at eval time without overrideAttrs: nixpkgs injects mainProgram
# into derivation construction, so overrideAttrs would fork a redundant build.
{semble}:
semble
// {
  meta = (semble.meta or {}) // {mainProgram = "semble-mcp";};
}
