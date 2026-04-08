# Top-level Bazel-style barrel. Each entry imports its per-package
# barrel. flake.nix walks this to compose homeManagerModules,
# devenvModules, and flake.lib contributions.
{
  claude-code = import ./claude-code;
  context7-mcp = import ./context7-mcp;
}
