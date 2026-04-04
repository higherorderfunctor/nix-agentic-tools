# Imports all home-manager modules.
# Each module is a no-op when its enable option is false.
{
  imports = [
    ./copilot-cli
    ./kiro-cli
    ./mcp-servers
    ./stacked-workflows
  ];
}
