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
    # The patched `workflows` variant is intentionally not distributed through
    # Cachix, but parity still matters: consumers reach it through
    # `ai.kiro.unlockedRolloutFeatures`, and a consumer-pin-bound build would
    # realize a different derivation from the one the local-only CI job tests.
    kiro-cli-workflows = {consumerPath = ["ai" "kiro-cli-workflows"];};
    kiro-gateway = {consumerPath = ["ai" "kiro-gateway"];};
    kiro-memory-distiller = {consumerPath = ["ai" "kiro-memory-distiller"];};
    semble = {consumerPath = ["ai" "semble"];};

    # ── Git tools — live at `consumerPkgs.ai.gitTools.<name>` ──
    git-absorb = {consumerPath = ["ai" "gitTools" "git-absorb"];};
    git-branchless = {consumerPath = ["ai" "gitTools" "git-branchless"];};
    git-revise = {consumerPath = ["ai" "gitTools" "git-revise"];};

    # ── Dev tools — live at `consumerPkgs.ai.devTools.<name>` ──
    beads = {consumerPath = ["ai" "devTools" "beads"];};
    gh = {consumerPath = ["ai" "devTools" "gh"];};
    glab = {consumerPath = ["ai" "devTools" "glab"];};
    oxlint = {consumerPath = ["ai" "devTools" "oxlint"];};
    strictdoc = {consumerPath = ["ai" "devTools" "strictdoc"];};
    tsgolint = {consumerPath = ["ai" "devTools" "tsgolint"];};

    # ── Generic supporting packages — live at `consumerPkgs.ai.generic.<name>` ──
    # Some of these ship files rather than binaries, but none are the
    # content-only class excluded in the header: each one runs a fetcher
    # and an stdenv derivation, so both are build inputs and both can
    # drift onto the consumer's pin. They belong here.
    arkenfox = {consumerPath = ["ai" "generic" "arkenfox"];};
    bruno = {consumerPath = ["ai" "generic" "bruno"];};
    btop = {consumerPath = ["ai" "generic" "btop"];};
    bun = {consumerPath = ["ai" "generic" "bun"];};
    catppuccin-btop = {consumerPath = ["ai" "generic" "catppuccin-btop"];};
    dns-root-hints = {consumerPath = ["ai" "generic" "dns-root-hints"];};
    fblog = {consumerPath = ["ai" "generic" "fblog"];};
    # The one platform-gated row. gluetun's `internal/routing` uses
    # Linux-only x/sys/unix constants, so overlays/default.nix omits the
    # ATTRIBUTE on non-Linux rather than only restricting meta.platforms —
    # and this row has to say the same thing, or the check aborts on
    # aarch64-darwin looking up a package that is not there.
    gluetun = {
      consumerPath = ["ai" "generic" "gluetun"];
      platforms = ["x86_64-linux"];
    };
    oh-my-posh = {consumerPath = ["ai" "generic" "oh-my-posh"];};
    otel-tui = {consumerPath = ["ai" "generic" "otel-tui"];};
    pnpm_10 = {consumerPath = ["ai" "generic" "pnpm_10"];};
    pnpm_11 = {consumerPath = ["ai" "generic" "pnpm_11"];};
    tree-sitter-strictdoc = {consumerPath = ["ai" "generic" "tree-sitter-strictdoc"];};

    # ── agnix + its mainProgram-override siblings ──
    # agnix itself is a flatDrvs entry at `consumerPkgs.ai.agnix`; the
    # -lsp/-mcp siblings live under the lspServers / mcpServers groups.
    agnix = {consumerPath = ["ai" "agnix"];};
    agnix-lsp = {consumerPath = ["ai" "lspServers" "agnix-lsp"];};
    agnix-mcp = {consumerPath = ["ai" "mcpServers" "agnix-mcp"];};

    # ── MCP servers — live at `consumerPkgs.ai.mcpServers.<name>` ──
    # aihubmix-mcp is ABSENT from nixpkgs, so it is a 100%-delta fresh
    # derivation. That does not exempt it: this check compares OUR pin
    # against a CONSUMER pin, never against nixpkgs, so a from-scratch
    # derivation still has to route every build input through `ourPkgs`.
    aihubmix-mcp = {consumerPath = ["ai" "mcpServers" "aihubmix-mcp"];};
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
    semble-mcp = {consumerPath = ["ai" "mcpServers" "semble-mcp"];};
    sympy-mcp = {consumerPath = ["ai" "mcpServers" "sympy-mcp"];};

    # ── Special — top-level names that don't match a grouped attr path ──
    # modelcontextprotocol-all-mcps is surfaced at the top level but lives
    # under pkgs.ai.mcpServers.modelContextProtocol.all-mcps on the grouped
    # side.
    modelcontextprotocol-all-mcps = {consumerPath = ["ai" "mcpServers" "modelContextProtocol" "all-mcps"];};
  };
}
