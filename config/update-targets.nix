# config/update-targets.nix — central config.update.targets contribution.
#
# Declares every package's update row EXCEPT effect-mcp, which carries its own
# co-located overlays/mcp-servers/effect-mcp.update.nix (disjoint keys, no
# collision). Merged with lib/update.nix (the option declaration) and the
# effect-mcp contribution by lib.evalModules into the `.#updateTargets` flake
# output — the single source of truth that replaced config/update-matrix.nix.
#
# `file` is a repo-relative POSIX path STRING equal to what
# resolve_overlay_file prints for each main-tracking upstream (asserted
# byte-identical by checks/update-targets-parity.nix); `null` for the binary
# (--use-update-script) packages, which self-manage their sources.
#
# All non-flake-input packages go through nix-update. Per-platform binary
# packages use --use-update-script.
_: {
  config.update.targets = {
    # ── Main-tracking (rev bumped from default branch, hashes via nix-update) ──
    agnix = {
      file = "overlays/agnix.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/agent-sh/agnix.git";
      dependsOn = ["rust-overlay"];
    };
    context7-mcp = {
      file = "overlays/mcp-servers/context7-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/upstash/context7.git";
    };
    git-absorb = {
      file = "overlays/git-tools/git-absorb.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/tummychow/git-absorb.git";
      dependsOn = ["rust-overlay"];
    };
    git-intel-mcp = {
      file = "overlays/mcp-servers/git-intel-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/hoangsonww/GitIntel-MCP-Server.git";
    };
    git-revise = {
      file = "overlays/git-tools/git-revise.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/mystor/git-revise.git";
    };
    github-mcp = {
      file = "overlays/mcp-servers/github-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/github/github-mcp-server.git";
    };
    gitlab-mcp = {
      file = "overlays/mcp-servers/gitlab-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/zereight/gitlab-mcp.git";
    };
    kagi-mcp = {
      file = "overlays/mcp-servers/kagi-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/kagisearch/kagimcp.git";
    };
    kiro-gateway = {
      file = "overlays/kiro-gateway.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/jwadow/kiro-gateway.git";
    };
    mcp-language-server = {
      file = "overlays/mcp-servers/mcp-language-server.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/isaacphi/mcp-language-server.git";
    };
    mcp-proxy = {
      file = "overlays/mcp-servers/mcp-proxy.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/sparfenyuk/mcp-proxy.git";
    };
    modelcontextprotocol-filesystem-mcp = {
      file = "overlays/mcp-servers/modelcontextprotocol/default.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/modelcontextprotocol/servers.git";
    };
    openmemory-mcp = {
      file = "overlays/mcp-servers/openmemory-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/CaviraOSS/OpenMemory.git";
    };
    # oxlint overrides three hashes: src, cargoDeps (fetchCargoVendor), pnpmDeps
    # (fetchPnpmDeps). Validated 2026-07-21: one `nix-update --version skip` pass
    # re-derives all three to their distinct correct values (each via its own
    # `outputHash=""` build), so the standard main-tracking flow works.
    oxlint = {
      file = "overlays/dev-tools/oxlint.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/oxc-project/oxc.git";
    };
    sympy-mcp = {
      file = "overlays/mcp-servers/sympy-mcp.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/sdiehl/sympy-mcp.git";
    };
    # tsgolint src uses fetchSubmodules (typescript-go). The rev-bump pre-step's
    # `nix flake prefetch` writes a submodule-less src hash, but nix-update then
    # self-corrects it — its `outputHash=""` src rebuild respects fetchSubmodules,
    # yielding the right hash (+ vendorHash) before the build-verify. Validated
    # 2026-07-21: standard main-tracking flow works, no bespoke updateScript.
    tsgolint = {
      file = "overlays/dev-tools/tsgolint.nix";
      flags = ["--version" "skip"];
      git = "https://github.com/oxc-project/tsgolint.git";
    };

    # ── Binary packages (custom updateScript handles per-platform fetches) ──
    chatgpt-codex = {flags = ["--use-update-script" "--override-filename" "overlays/chatgpt-codex.nix"];};
    claude-code = {flags = ["--use-update-script"];};
    copilot-cli = {flags = ["--use-update-script" "--override-filename" "overlays/copilot-cli.nix"];};
    kimchi = {flags = ["--use-update-script" "--override-filename" "overlays/kimchi.nix"];};
    kiro-cli = {flags = ["--use-update-script" "--override-filename" "overlays/kiro-cli.nix"];};
  };

  # Packages excluded from the update loop entirely.
  # Regex patterns matched against flake package names.
  config.update.excludePatterns = [
    "^agnix-lsp$"
    "^agnix-mcp$"
    "^docs"
    "^instructions-"
    "^nixos-mcp$"
    "^serena-mcp$"
  ];
}
