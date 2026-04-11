# config/update-matrix.nix — single source of truth for package update config.
#
# Consumed by:
#   - devenv.nix: generates per-package update tasks
#   - flake.nix: exposes as updateMatrix output for CI matrix generation
#
# Three categories:
#   nixUpdate: packages managed by nix-update (version + hash inline in .nix)
#   updateScript: per-platform binary packages with sources.json
#   exclude: packages NOT in the update loop (generated, proxies, flake inputs)
{
  # Packages updated via `nix run nix-update -- --flake <name> --commit`.
  # Value is extra flags string (empty = defaults).
  nixUpdate = {
    agnix = "";
    any-buddy = "";
    context7-mcp = "--url https://github.com/upstash/context7 --version-regex '@upstash/context7-mcp@(.*)' --override-filename overlays/mcp-servers/context7-mcp.nix";
    effect-mcp = "";
    git-absorb = "";
    git-branchless = "";
    git-intel-mcp = "";
    git-revise = "";
    github-mcp = "";
    kagi-mcp = "";
    kiro-gateway = "";
    mcp-language-server = "";
    mcp-proxy = "";
    modelcontextprotocol-all-mcps = "";
    openmemory-mcp = "";
    sympy-mcp = "";
  };

  # Per-platform binary packages updated via passthru.updateScript.
  # These write to overlays/<name>-sources.json.
  updateScript = [
    "claude-code"
    "copilot-cli"
    "kiro-cli"
  ];

  # Packages excluded from the update loop entirely.
  # Regex patterns matched against flake package names.
  excludePatterns = [
    "^instructions-"
    "^docs"
    "^agnix-lsp$"
    "^agnix-mcp$"
    "^nixos-mcp$"
    "^serena-mcp$"
  ];
}
