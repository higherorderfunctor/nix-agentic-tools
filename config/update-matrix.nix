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
    # ── Main-tracking (--version skip: version computed from source + rev) ──
    agnix = "--version skip";
    any-buddy = "--version skip";
    effect-mcp = "--version skip";
    git-absorb = "--version skip";
    git-intel-mcp = "--version skip";
    git-revise = "--version skip";
    kagi-mcp = "--version skip";
    kiro-gateway = "--version skip";
    mcp-language-server = "--version skip";
    mcp-proxy = "--version skip";
    modelcontextprotocol-all-mcps = "--version skip";
    openmemory-mcp = "--version skip";
    sympy-mcp = "--version skip";

    # ── Release-tracking (nix-update discovers version from tags) ──
    context7-mcp = "--url https://github.com/upstash/context7 --version-regex '@upstash/context7-mcp@(.*)' --override-filename overlays/mcp-servers/context7-mcp.nix";
    github-mcp = "";

    # ── Binary packages (custom updateScript handles per-platform fetches) ──
    claude-code = "--use-update-script";
    copilot-cli = "--use-update-script --override-filename overlays/copilot-cli.nix";
    kiro-cli = "--use-update-script --override-filename overlays/kiro-cli.nix";
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
