# config/cache-hit-parity-targets.nix — central config.checks.cacheHitParity
# contribution.
#
# Declares every package's cache-hit-parity consumer attr-path: the dotted
# lookup under `consumerPkgs` that mirrors where the overlay actually exposes
# the package to downstream users. Merged with lib/checks.nix (the option
# declaration) by lib.evalModules into the `.#cacheHitParityTargets` flake
# output — the single source of truth that replaced the six hardcoded lists in
# checks/cache-hit-parity.nix.
#
# Per-package co-location (each package carrying its own row alongside its
# overlay) is deferred Track B; for now add rows here.
#
# Two classes of package are intentionally absent, carried over from the old
# check's comments so a future editor knows why:
#
#   - Content-only packages (coding-standards, fragments-ai,
#     stacked-workflows-content) — they have no build inputs, so their store
#     paths are already independent of the consumer pin.
#   - Instruction derivations (instructions-*) — they are produced by flake.nix
#     itself, not the overlay, so they do not exist on the consumer side.
_: {
  config.checks.cacheHitParity = {
    # ── AI CLIs — live at `consumerPkgs.ai.<name>` ──
    chatgpt-codex = {consumerPath = ["ai" "chatgpt-codex"];};
    claude-code = {consumerPath = ["ai" "claude-code"];};
    copilot-cli = {consumerPath = ["ai" "copilot-cli"];};
    kimchi = {consumerPath = ["ai" "kimchi"];};
    kiro-cli = {consumerPath = ["ai" "kiro-cli"];};
    kiro-gateway = {consumerPath = ["ai" "kiro-gateway"];};
    kiro-memory-distiller = {consumerPath = ["ai" "kiro-memory-distiller"];};

    # ── Git tools — live at `consumerPkgs.gitTools.<name>` ──
    git-absorb = {consumerPath = ["gitTools" "git-absorb"];};
    git-branchless = {consumerPath = ["gitTools" "git-branchless"];};
    git-revise = {consumerPath = ["gitTools" "git-revise"];};

    # ── Dev tools (linters) — live at `consumerPkgs.devTools.<name>` ──
    oxlint = {consumerPath = ["devTools" "oxlint"];};
    tsgolint = {consumerPath = ["devTools" "tsgolint"];};

    # ── agnix + its mainProgram-override siblings ──
    # agnix itself is a flatDrvs entry at `consumerPkgs.ai.agnix`; the
    # -lsp/-mcp siblings live under the lspServers / mcpServers groups.
    agnix = {consumerPath = ["ai" "agnix"];};
    agnix-lsp = {consumerPath = ["ai" "lspServers" "agnix-lsp"];};
    agnix-mcp = {consumerPath = ["ai" "mcpServers" "agnix-mcp"];};

    # ── MCP servers — live at `consumerPkgs.ai.mcpServers.<name>` ──
    context7-mcp = {consumerPath = ["ai" "mcpServers" "context7-mcp"];};
    effect-mcp = {consumerPath = ["ai" "mcpServers" "effect-mcp"];};
    git-intel-mcp = {consumerPath = ["ai" "mcpServers" "git-intel-mcp"];};
    github-mcp = {consumerPath = ["ai" "mcpServers" "github-mcp"];};
    gitlab-mcp = {consumerPath = ["ai" "mcpServers" "gitlab-mcp"];};
    kagi-mcp = {consumerPath = ["ai" "mcpServers" "kagi-mcp"];};
    mcp-language-server = {consumerPath = ["ai" "mcpServers" "mcp-language-server"];};
    mcp-proxy = {consumerPath = ["ai" "mcpServers" "mcp-proxy"];};
    nixos-mcp = {consumerPath = ["ai" "mcpServers" "nixos-mcp"];};
    openmemory-mcp = {consumerPath = ["ai" "mcpServers" "openmemory-mcp"];};
    serena-mcp = {consumerPath = ["ai" "mcpServers" "serena-mcp"];};
    sympy-mcp = {consumerPath = ["ai" "mcpServers" "sympy-mcp"];};

    # ── Special — top-level names that don't match a grouped attr path ──
    # modelcontextprotocol-all-mcps is surfaced at the top level but lives
    # under pkgs.ai.mcpServers.modelContextProtocol.all-mcps on the grouped
    # side.
    modelcontextprotocol-all-mcps = {consumerPath = ["ai" "mcpServers" "modelContextProtocol" "all-mcps"];};
  };
}
