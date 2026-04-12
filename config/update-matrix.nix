# config/update-matrix.nix — single source of truth for package update config.
#
# Consumed by:
#   - devenv.nix: generates per-package update tasks
#   - flake.nix: exposes as updateMatrix output for CI matrix generation
#
# All non-flake-input packages go through nix-update. No exceptions.
# Per-platform binary packages use --use-update-script flag.
{
  # Packages updated via `nix run nix-update -- --flake <name> --commit`.
  # Value is extra flags string (empty = defaults).
  nixUpdate = {
    agnix = "";
    any-buddy = "";
    claude-code = "--use-update-script";
    context7-mcp = "--url https://github.com/upstash/context7 --version-regex '@upstash/context7-mcp@(.*)' --override-filename overlays/mcp-servers/context7-mcp.nix";
    copilot-cli = "--use-update-script --override-filename overlays/copilot-cli.nix";
    effect-mcp = "";
    git-absorb = "";
    git-intel-mcp = "";
    git-revise = "";
    github-mcp = "";
    kagi-mcp = "";
    kiro-cli = "--use-update-script --override-filename overlays/kiro-cli.nix";
    kiro-gateway = "";
    mcp-language-server = "";
    mcp-proxy = "";
    modelcontextprotocol-all-mcps = "";
    openmemory-mcp = "";
    sympy-mcp = "";
  };

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
