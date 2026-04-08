# Top-level Bazel-style barrel. Each entry imports its per-package
# barrel. flake.nix walks this to compose homeManagerModules,
# devenvModules, and flake.lib contributions.
{
  any-buddy = import ./any-buddy;
  claude-code = import ./claude-code;
  context7-mcp = import ./context7-mcp;
  copilot-cli = import ./copilot-cli;
  kiro-cli = import ./kiro-cli;
  kiro-gateway = import ./kiro-gateway;
}
