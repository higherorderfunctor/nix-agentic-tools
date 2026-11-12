# z.ai credential defaults, keeping measured endpoints and tool repairs with their vendor.
{lib}: let
  # Read the measured z.ai defaults at their owning vendor.
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  # Use CPA's aggregate so missing or divergent vendor facts fail at their source.
  fact = facts.get (facts.load {dir = ../../extracted;}).aggregate;
in
  fact "zAi"
  // {
    codexShellArgCleanup = true;
    toolAliases.ToolSearch = "ToolSearch_";
  }
