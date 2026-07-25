# overlays/default.nix
# Unified binary-package overlay.
#
# Package index: see overlays/README.md for a table of every package's
# source method, build tool, nixpkgs status, dep hashes, and TODOs.
#
# Aggregates derivations into grouped namespaces:
#   pkgs.ai.*                — flat AI CLIs and unique tools
#   pkgs.ai.mcpServers.*     — MCP server packages + proxies
#   pkgs.ai.lspServers.*     — LSP server proxies
#   pkgs.devTools.*          — dev tools (linters)
#   pkgs.generic.*           — packages with nothing agentic about them
#   pkgs.gitTools.*          — git workflow tools
#
# `generic` is a split-ready subtree (overlays/generic/) for packages
# that are not agentic-tools-specific and are earmarked for a possible
# future repo split. Keeping them in one directory + one namespace makes
# that split a directory move rather than an archaeology exercise.
#
# Each per-package file takes {inputs, final, ...} and manages its
# own source — fetchFromGitHub with inline hashes for upstream
# packages, or an in-repo path for packages built from this repo
# (e.g. kiro-memory-distiller).
{inputs, ...}: final: _prev: let
  # Unfree guard. Checks if the derivation has an unfree license and
  # wraps it so the consumer's allowUnfree config is respected. If the
  # package is free, returns the original derivation unwrapped.
  #
  # Why: ourPkgs builds with allowUnfree (internal to the overlay for
  # cache-hit parity). Without this guard, unfree derivations produced
  # by ourPkgs would silently bypass the consumer's unfree preference.
  # The wrapper uses final.symlinkJoin (consumer's nixpkgs) with the
  # unfree meta.license, triggering the standard check at eval time.
  # See memory/project_unfree_guard_pattern.md for rationale.
  isUnfree = drv: let
    license = drv.meta.license or {};
  in
    if builtins.isList license
    then builtins.any (l: !(l.free or true)) license
    else !(license.free or true);

  ensureUnfreeCheck = drv:
    if isUnfree drv
    then
      final.symlinkJoin {
        inherit (drv) name version;
        paths = [drv];
        meta = drv.meta or {};
        passthru = drv.passthru or {};
      }
    else drv;

  # ── Flat AI CLIs and unique tools ──────────────────────────────────
  flatDrvs = {
    agnix = import ./agnix.nix {
      inherit inputs final;
    };
    chatgpt-codex = import ./chatgpt-codex.nix {
      inherit inputs final;
    };
    claude-code = import ./claude-code.nix {
      inherit inputs final;
    };
    copilot-cli = import ./copilot-cli.nix {
      inherit inputs final;
    };
    kimchi = import ./kimchi.nix {
      inherit inputs final;
    };
    kiro-cli = import ./kiro-cli.nix {
      inherit inputs final;
    };
    kiro-gateway = import ./kiro-gateway.nix {
      inherit inputs final;
    };
    kiro-memory-distiller = import ./kiro-memory-distiller.nix {
      inherit inputs final;
    };
  };

  # ── MCP servers ────────────────────────────────────────────────────
  # modelcontextprotocol/servers mono-repo — directory with shared
  # source, per-package JS builds for parallelism, independent Python
  # builds. Namespaced under modelContextProtocol.
  modelContextProtocol = import ./mcp-servers/modelcontextprotocol {inherit inputs final;};

  mcpServerDrvs = {
    inherit modelContextProtocol;
    context7-mcp = import ./mcp-servers/context7-mcp.nix {
      inherit inputs final;
    };
    effect-mcp = import ./mcp-servers/effect-mcp.nix {
      inherit inputs final;
    };
    git-intel-mcp = import ./mcp-servers/git-intel-mcp.nix {
      inherit inputs final;
    };
    github-mcp = import ./mcp-servers/github-mcp.nix {
      inherit inputs final;
    };
    gitlab-mcp = import ./mcp-servers/gitlab-mcp.nix {
      inherit inputs final;
    };
    kagi-mcp = import ./mcp-servers/kagi-mcp.nix {
      inherit inputs final;
    };
    mcp-language-server = import ./mcp-servers/mcp-language-server.nix {
      inherit inputs final;
    };
    mcp-proxy = import ./mcp-servers/mcp-proxy.nix {
      inherit inputs final;
    };
    nixos-mcp = import ./mcp-servers/nixos-mcp.nix {inherit inputs final;};
    openmemory-mcp = import ./mcp-servers/openmemory-mcp.nix {
      inherit inputs final;
    };
    serena-mcp = import ./mcp-servers/serena-mcp.nix {inherit inputs final;};
    sympy-mcp = import ./mcp-servers/sympy-mcp.nix {
      inherit inputs final;
    };
  };

  # ── agnix multi-binary overrides ────────────────────────────────────
  # agnix builds three binaries (agnix, agnix-lsp, agnix-mcp) from one
  # crate workspace. The base derivation (flatDrvs.agnix) has
  # mainProgram = "agnix" (the CLI). These overrides produce derivations
  # with mainProgram pointing at the MCP / LSP binaries so
  # `lib.getExe pkgs.ai.mcpServers.agnix-mcp` returns the right binary.
  agnixMcp = import ./mcp-servers/agnix-mcp.nix {inherit (flatDrvs) agnix;};
  agnixLsp = import ./lsp-servers/agnix-lsp.nix {inherit (flatDrvs) agnix;};

  # ── Generic (non-agentic) packages ─────────────────────────────────
  # Split-ready subtree — see the header. Nothing here depends on the
  # rest of the repo beyond overlays/lib.nix.
  genericDrvs =
    {
      arkenfox = import ./generic/arkenfox.nix {
        inherit inputs final;
      };
      btop = import ./generic/btop.nix {
        inherit inputs final;
      };
      bun = import ./generic/bun.nix {
        inherit inputs final;
      };
      catppuccin-btop = import ./generic/catppuccin-btop.nix {
        inherit inputs final;
      };
      dns-root-hints = import ./generic/dns-root-hints.nix {
        inherit inputs final;
      };
      fblog = import ./generic/fblog.nix {
        inherit inputs final;
      };
      gh = import ./generic/gh.nix {
        inherit inputs final;
      };
      oh-my-posh = import ./generic/oh-my-posh.nix {
        inherit inputs final;
      };
      otel-tui = import ./generic/otel-tui.nix {
        inherit inputs final;
      };
      # Majored, namespaced-only. NEVER a top-level `pkgs.pnpm_<N>`:
      # overlays/dev-tools/oxlint.nix binds `ourPkgs.pnpm_10` out of a
      # fresh nixpkgs import that this overlay is not applied to, and the
      # additive contract is what lets consumers adopt the overlay without
      # auditing it. Both files delegate to ./generic/pnpm-major.nix.
      pnpm_10 = import ./generic/pnpm_10.nix {
        inherit inputs final;
      };
      pnpm_11 = import ./generic/pnpm_11.nix {
        inherit inputs final;
      };
    }
    # gluetun is the one genuinely LINUX-ONLY package here: `internal/routing`
    # uses `unix.RT_TABLE_MAIN`/`RT_TABLE_LOCAL`, which x/sys/unix defines on
    # Linux only (measured by cross-compiling for darwin/arm64). Gating the
    # ATTRIBUTE — not just `meta.platforms` — is what keeps the required
    # aarch64-darwin leg green: a restrictive `meta.platforms` alone still
    # leaves `packages.aarch64-darwin.gluetun` present, and forcing its
    # `drvPath` (which both `nix flake check` and CI's darwin build do) throws
    # "not available on the requested hostPlatform". Absent is the honest
    # shape. `config.checks.cacheHitParity.gluetun.platforms` mirrors this.
    // final.lib.optionalAttrs final.stdenv.hostPlatform.isLinux {
      gluetun = import ./generic/gluetun.nix {
        inherit inputs final;
      };
    };

  # ── Git tools ──────────────────────────────────────────────────────
  gitToolDrvs = {
    git-absorb = import ./git-tools/git-absorb.nix {
      inherit inputs final;
    };
    git-branchless = import ./git-tools/git-branchless.nix {
      inherit inputs final;
    };
    git-revise = import ./git-tools/git-revise.nix {
      inherit inputs final;
    };
  };
  # ── Dev tools (linters/formatters) ─────────────────────────────────
  devToolDrvs = {
    oxlint = import ./dev-tools/oxlint.nix {
      inherit inputs final;
    };
    tsgolint = import ./dev-tools/tsgolint.nix {
      inherit inputs final;
    };
  };
  # Apply ensureUnfreeCheck to every package at the output level.
  # No manual per-package wrapping needed — if a package has an unfree
  # license, it gets the symlinkJoin wrapper automatically.
  guard = builtins.mapAttrs (_: ensureUnfreeCheck);
in {
  ai =
    guard flatDrvs
    // {
      mcpServers = guard (mcpServerDrvs // {agnix-mcp = agnixMcp;});
      lspServers = guard {agnix-lsp = agnixLsp;};
    };
  devTools = guard devToolDrvs;
  generic = guard genericDrvs;
  gitTools = guard gitToolDrvs;
}
