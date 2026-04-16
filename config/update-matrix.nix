# config/update-matrix.nix — single source of truth for package update config.
#
# Consumed by:
#   - config/generate-update-ninja.nix: generates ninja DAG targets
#   - flake.nix: exposes as updateMatrix output for CI matrix generation
#
# All non-flake-input packages go through nix-update. No exceptions.
# Per-platform binary packages use --use-update-script flag.
{
  # Packages updated via nix-update.
  # flags: extra nix-update CLI flags
  # git: (optional) repo URL for main-tracking packages — enables rev bump
  #       before nix-update runs (git ls-remote HEAD → sed rev line)
  nixUpdate = {
    # ── Main-tracking (rev bumped from default branch, hashes via nix-update) ──
    agnix = {
      flags = "--version skip";
      git = "https://github.com/agent-sh/agnix.git";
    };
    context7-mcp = {
      flags = "--version skip";
      git = "https://github.com/upstash/context7.git";
    };
    effect-mcp = {
      flags = "--version skip";
      git = "https://github.com/tim-smart/effect-mcp.git";
    };
    git-absorb = {
      flags = "--version skip";
      git = "https://github.com/tummychow/git-absorb.git";
    };
    git-intel-mcp = {
      flags = "--version skip";
      git = "https://github.com/hoangsonww/GitIntel-MCP-Server.git";
    };
    git-revise = {
      flags = "--version skip";
      git = "https://github.com/mystor/git-revise.git";
    };
    github-mcp = {
      flags = "--version skip";
      git = "https://github.com/github/github-mcp-server.git";
    };
    kagi-mcp = {
      flags = "--version skip";
      git = "https://github.com/kagisearch/kagimcp.git";
    };
    kiro-gateway = {
      flags = "--version skip";
      git = "https://github.com/jwadow/kiro-gateway.git";
    };
    mcp-language-server = {
      flags = "--version skip";
      git = "https://github.com/isaacphi/mcp-language-server.git";
    };
    mcp-proxy = {
      flags = "--version skip";
      git = "https://github.com/sparfenyuk/mcp-proxy.git";
    };
    modelcontextprotocol-all-mcps = {
      flags = "--version skip";
      git = "https://github.com/modelcontextprotocol/servers.git";
    };
    openmemory-mcp = {
      flags = "--version skip";
      git = "https://github.com/CaviraOSS/OpenMemory.git";
    };
    sympy-mcp = {
      flags = "--version skip";
      git = "https://github.com/sdiehl/sympy-mcp.git";
    };

    # ── Binary packages (custom updateScript handles per-platform fetches) ──
    claude-code = {flags = "--use-update-script";};
    copilot-cli = {flags = "--use-update-script --override-filename overlays/copilot-cli.nix";};
    kiro-cli = {flags = "--use-update-script --override-filename overlays/kiro-cli.nix";};
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
