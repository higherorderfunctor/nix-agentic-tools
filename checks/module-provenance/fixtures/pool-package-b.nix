# Positive-control package B deliberately claims package A's keys.
{lib, ...}: let
  pools = [
    "agents"
    "environmentVariables"
    "mcpServers"
    "rules"
    "skills"
  ];
  claims = lib.genAttrs pools (_: {shared = "package-b";});
in {
  config.ai = claims // {claude = claims;};
}
