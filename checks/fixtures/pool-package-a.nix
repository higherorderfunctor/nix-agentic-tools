# Positive-control package A for the normalized-pool provenance guard.
{lib, ...}: let
  pools = [
    "agents"
    "environmentVariables"
    "lspServers"
    "mcpServers"
    "rules"
    "skills"
  ];
  claims = lib.genAttrs pools (_: {shared = "package-a";});
in {
  config.ai = claims // {claude = claims;};
}
