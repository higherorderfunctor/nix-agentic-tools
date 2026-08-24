# overlays/default.nix
# Unified binary-package overlay.
#
# Package index: see overlays/README.md for a table of every package's
# source method, build tool, nixpkgs status, dep hashes, and TODOs.
#
# Aggregates derivations into grouped namespaces:
#   pkgs.ai.*                — flat AI CLIs and unique tools
#   pkgs.ai.devTools.*       — developer tools used by agents
#   pkgs.ai.generic.*        — temporarily unclassified supporting packages
#   pkgs.ai.gitTools.*       — git workflow tools
#   pkgs.ai.lspServers.*     — LSP server proxies
#   pkgs.ai.mcpServers.*     — MCP server packages + proxies
#
# `generic` is a temporary split-ready subtree (overlays/generic/) for
# supporting packages that have not yet earned a more specific category.
# Keeping it under `pkgs.ai` preserves one non-shadowing consumer namespace
# until a later taxonomy and nixpkgs-namespace decision.
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

  # Bound once and shared, so `kiro-cli` and `kiro-cli-workflows` below are
  # provably the same instantiation rather than two that merely ought to agree.
  # A second `import` of this file does in fact produce an identical derivation
  # — `import` is memoized and the arguments are the same — so this is clarity
  # and cheap insurance, NOT a fix for a measured divergence.
  kiroCliDrv = import ./kiro-cli.nix {inherit inputs final;};
  sembleDrv = import ./semble.nix {inherit inputs final;};

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
    kiro-cli = kiroCliDrv;
    # The canonical `workflows` unlock, exposed as a package so CI can build
    # exactly what the module resolves to.
    #
    # CI COVERAGE. The dedicated `kiro-patched` job builds this package on BOTH
    # matrix legs, putting the Darwin-only walk + codesign + exec assertion in
    # CI without Cachix credentials. Reachable only through
    # `passthru.withRolloutFeatures`, the patched variant was previously
    # invisible to CI and the Darwin path could regress unnoticed — which is
    # precisely how it shipped broken in #640. Both legs are REQUIRED status
    # checks as of #895, so a break here holds the merge rather than merely
    # reporting; the job is always-reporting and scopes its expensive steps to
    # changes that can move this store path.
    #
    # LOCAL-ONLY DISTRIBUTION. This is deliberately excluded from the normal
    # cache-writing package build. A separate CI job builds it on both systems
    # without Cachix and with this repo's substituter removed, so the patched
    # proprietary binary is tested but never distributed by this project.
    # Consumers enabling `ai.kiro.unlockedRolloutFeatures = ["workflows"]`
    # fetch the upstream release and realize this derivation locally.
    #
    # It rides `flatDrvs` so `guard` applies and the unfree check still fires.
    # Do NOT hoist it out of this attrset to dodge that — the raw
    # `withRolloutFeatures` result is deliberately UNGUARDED (see
    # overlays/kiro-cli.nix).
    #
    # CI realizes it on every run (subject only to the runner's local store),
    # including version bumps where the upstream .app layout may have moved and
    # the assertion is most valuable.
    kiro-cli-workflows = kiroCliDrv.withRolloutFeatures ["workflows"];
    kiro-gateway = import ./kiro-gateway.nix {
      inherit inputs final;
    };
    kiro-memory-distiller = import ./kiro-memory-distiller.nix {
      inherit inputs final;
    };
    semble = sembleDrv;
  };

  # ── MCP servers ────────────────────────────────────────────────────
  # modelcontextprotocol/servers mono-repo — directory with shared
  # source, per-package JS builds for parallelism, independent Python
  # builds. Namespaced under modelContextProtocol.
  modelContextProtocol = import ./mcp-servers/modelcontextprotocol {inherit inputs final;};

  mcpServerDrvs = {
    inherit modelContextProtocol;
    # Tracks npm dist-tags.latest but is bumped BY HAND, and so is
    # deliberately absent from config.update.targets — a local patch against
    # upstream's build output cannot be carried across an upstream rewrite
    # by any update script (the 1.0.0 -> 1.1.0 bump needed it re-authored).
    # update.yml's "Detect a newer @aihubmix/mcp on npm" step watches for
    # the next release. See the header of ./mcp-servers/aihubmix-mcp.nix.
    aihubmix-mcp = import ./mcp-servers/aihubmix-mcp.nix {
      inherit inputs final;
    };
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
    semble-mcp = import ./mcp-servers/semble-mcp.nix {semble = sembleDrv;};
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

  # ── Generic supporting packages ────────────────────────────────────
  # Temporary split-ready subtree — see the header. Nothing here depends on
  # the rest of the repo beyond overlays/lib.nix.
  genericDrvs =
    {
      arkenfox = import ./generic/arkenfox.nix {
        inherit inputs final;
      };
      # Wraps the BUILDER via `.override`, not the output attrs: an
      # `npmDepsHash` injected with `overrideAttrs` on a `buildNpmPackage`
      # is inert. See the header of ./generic/bruno.nix.
      bruno = import ./generic/bruno.nix {
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
      tree-sitter-strictdoc = import ./generic/tree-sitter-strictdoc.nix {
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
  # ── Dev tools ──────────────────────────────────────────────────────
  devToolDrvs = {
    beads = import ./dev-tools/beads.nix {
      inherit inputs final;
    };
    gh = import ./dev-tools/gh.nix {
      inherit inputs final;
    };
    # Sidecar-pinned like gh, but on the bruno CONTRACT, not gh's:
    # nixpkgs' fetcher carries a `postFetch`, so neither hash can come
    # from a prefetch. See the header of ./dev-tools/glab.nix.
    glab = import ./dev-tools/glab.nix {
      inherit inputs final;
    };
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
      devTools = guard devToolDrvs;
      generic = guard genericDrvs;
      gitTools = guard gitToolDrvs;
      lspServers = guard {agnix-lsp = agnixLsp;};
      mcpServers = guard (mcpServerDrvs // {agnix-mcp = agnixMcp;});
    };
}
