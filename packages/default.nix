# Top-level Bazel-style barrel. Each entry imports its per-package
# barrel. flake.nix walks this to compose homeManagerModules,
# devenvModules, and flake.lib contributions.
{
  agnix = import ./agnix;
  any-buddy = import ./any-buddy;
  claude-code = import ./claude-code;
  context7-mcp = import ./context7-mcp;
  copilot-cli = import ./copilot-cli;
  effect-mcp = import ./effect-mcp;
  fetch-mcp = import ./fetch-mcp;
  git-absorb = import ./git-absorb;
  git-branchless = import ./git-branchless;
  git-intel-mcp = import ./git-intel-mcp;
  git-mcp = import ./git-mcp;
  git-revise = import ./git-revise;
  github-mcp = import ./github-mcp;
  kagi-mcp = import ./kagi-mcp;
  kiro-cli = import ./kiro-cli;
  kiro-gateway = import ./kiro-gateway;
  mcp-language-server = import ./mcp-language-server;
  mcp-proxy = import ./mcp-proxy;
  nixos-mcp = import ./nixos-mcp;
  openmemory-mcp = import ./openmemory-mcp;
  sequential-thinking-mcp = import ./sequential-thinking-mcp;
  serena-mcp = import ./serena-mcp;
  sympy-mcp = import ./sympy-mcp;
}
