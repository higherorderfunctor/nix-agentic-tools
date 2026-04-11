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
#   pkgs.gitTools.*           — git workflow tools
#
# Each per-package file takes {inputs, final, ...} and manages its
# own source via fetchFromGitHub with inline hashes.
{inputs, ...}: final: prev: let
  # Unfree guard. Checks if the derivation has an unfree license and
  # wraps it so the consumer's allowUnfree config is respected. If the
  # package is free, returns the original derivation unwrapped.
  #
  # Why: ourPkgs builds with allowUnfree (internal to the overlay for
  # cache-hit parity). Without this guard, unfree derivations produced
  # by ourPkgs would silently bypass the consumer's unfree preference.
  # The wrapper uses final.symlinkJoin (consumer's nixpkgs) with the
  # unfree meta.license, triggering the standard check at eval time.
  # See memory/project_nvfetcher_overlay_pattern.md for rationale.
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
    any-buddy = import ./any-buddy.nix {
      inherit inputs final;
    };
    claude-code = import ./claude-code.nix {
      inherit inputs final prev;
      lockFile = ./locks/claude-code-package-lock.json;
    };
    copilot-cli = import ./copilot-cli.nix {
      inherit inputs final;
    };
    kiro-cli = import ./kiro-cli.nix {
      inherit inputs final;
    };
    kiro-gateway = import ./kiro-gateway.nix {
      inherit inputs final;
    };
  };

  # ── MCP servers ────────────────────────────────────────────────────
  # modelcontextprotocol/servers mono-repo — directory with shared
  # source, per-package JS builds for parallelism, independent Python
  # builds. Namespaced under modelContextProtocol.
  modelContextProtocol = import ./mcp-servers/modelcontextprotocol {inherit inputs final;};

  mcpServerDrvs =
    modelContextProtocol
    // {
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
  gitTools = guard gitToolDrvs;
}
