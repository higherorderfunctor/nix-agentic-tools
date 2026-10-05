# Passing control: another package may claim different keys in every pool.
{lib, ...}: let
  pools = [
    "agents"
    "environmentVariables"
    "extraSystemPrompt"
    "lspServers"
    "mcpServers"
    "rules"
    "skills"
  ];
  claims = lib.genAttrs pools (_: {distinct = "package-distinct";});
in {
  config.ai = claims // {claude = claims;};
}
