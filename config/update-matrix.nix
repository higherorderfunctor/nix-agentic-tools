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
    gitlab-mcp = {
      flags = "--version skip";
      git = "https://github.com/zereight/gitlab-mcp.git";
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
    modelcontextprotocol-filesystem-mcp = {
      flags = "--version skip";
      git = "https://github.com/modelcontextprotocol/servers.git";
    };
    openmemory-mcp = {
      flags = "--version skip";
      git = "https://github.com/CaviraOSS/OpenMemory.git";
    };
    # oxlint overrides three hashes: src, cargoDeps (fetchCargoVendor), pnpmDeps
    # (fetchPnpmDeps). Validated 2026-07-21: one `nix-update --version skip` pass
    # re-derives all three to their distinct correct values (each via its own
    # `outputHash=""` build), so the standard main-tracking flow works.
    oxlint = {
      flags = "--version skip";
      git = "https://github.com/oxc-project/oxc.git";
    };
    sympy-mcp = {
      flags = "--version skip";
      git = "https://github.com/sdiehl/sympy-mcp.git";
    };
    # tsgolint src uses fetchSubmodules (typescript-go). The rev-bump pre-step's
    # `nix flake prefetch` writes a submodule-less src hash, but nix-update then
    # self-corrects it — its `outputHash=""` src rebuild respects fetchSubmodules,
    # yielding the right hash (+ vendorHash) before the build-verify. Validated
    # 2026-07-21: standard main-tracking flow works, no bespoke updateScript.
    tsgolint = {
      flags = "--version skip";
      git = "https://github.com/oxc-project/tsgolint.git";
    };

    # ── Binary packages (custom updateScript handles per-platform fetches) ──
    claude-code = {flags = "--use-update-script";};
    copilot-cli = {flags = "--use-update-script --override-filename overlays/copilot-cli.nix";};
    kimchi = {flags = "--use-update-script --override-filename overlays/kimchi.nix";};
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
