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
# Shared nvfetcher data comes from final.nv-sources (populated by
# nvSourcesOverlay in flake.nix), merged with sidecar hashes from
# ./hashes.json.
#
# Per-package files take custom argument sets (NOT uniform
# {nv-sources, ...} callers) because different packages have different
# needs — claude-code needs lockFile, kiro-cli needs nv-darwin, etc.
{inputs, ...}: final: prev: let
  hashes = builtins.fromJSON (builtins.readFile ./sources/hashes.json);
  # Dummy hash for auto-discovery: overlay defaults missing hashes to
  # this value. The update:hashes task builds each package, captures
  # "got:" from the hash mismatch, and writes the real hash to hashes.json.
  dummyHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  # hashes.json is keyed by PACKAGE name (flake output name).
  # nvfetcher sources are keyed by nvfetcher name (may differ).
  # `merge` handles the common case (same key); inline for exceptions.
  # Every dep hash field defaults to dummyHash so overlays can use
  # `inherit (nv) cargoHash;` without failing when hashes.json doesn't
  # have the entry yet. The update:hashes task auto-discovers and fills.
  nvSrc = name: final.nv-sources.${name} or {};
  hashDefaults = {
    cargoHash = dummyHash;
    npmDepsHash = dummyHash;
    pnpmDepsHash = dummyHash;
    srcHash = dummyHash;
    vendorHash = dummyHash;
  };
  merge = name: hashDefaults // nvSrc name // (hashes.${name} or {});

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

  nv = {
    # AI CLIs
    agnix = merge "agnix";
    any-buddy = merge "any-buddy";
    claude-code = merge "claude-code";
    copilot-cli-linux-x64 = merge "github-copilot-cli-linux-x64";
    copilot-cli-darwin-arm64 = merge "github-copilot-cli-darwin-arm64";
    kiro-cli-linux-x64 = merge "kiro-cli-linux-x64";
    kiro-cli-darwin-arm64 = merge "kiro-cli-darwin-arm64";
    kiro-gateway = merge "kiro-gateway";

    # Git tools
    git-absorb = merge "git-absorb";
    git-branchless = merge "git-branchless";
    git-revise = merge "git-revise";

    # MCP servers
    context7-mcp = merge "context7-mcp";
    effect-mcp = merge "effect-mcp";
    git-intel-mcp = merge "git-intel-mcp";
    github-mcp = hashDefaults // nvSrc "github-mcp-server" // (hashes."github-mcp" or {});
    kagi-mcp = hashDefaults // nvSrc "kagimcp" // (hashes."kagi-mcp" or {});
    mcp-language-server = merge "mcp-language-server";
    mcp-proxy = merge "mcp-proxy";
    # modelcontextprotocol/servers mono-repo — shared source, per-package version
    mcp-servers-mono = merge "modelcontextprotocol-servers";
    openmemory-mcp = merge "openmemory-mcp";
    sympy-mcp = merge "sympy-mcp";
  };

  # ── Flat AI CLIs and unique tools ──────────────────────────────────
  flatDrvs = {
    agnix = import ./agnix.nix {
      inherit inputs final;
      nv = nv.agnix;
    };
    any-buddy = import ./any-buddy.nix {
      inherit inputs final;
      nv = nv.any-buddy;
    };
    claude-code = import ./claude-code.nix {
      inherit inputs final prev;
      nv = nv.claude-code;
      lockFile = ./sources/locks/claude-code-package-lock.json;
    };
    copilot-cli = import ./copilot-cli.nix {
      inherit inputs final;
      nv-linux-x64 = nv.copilot-cli-linux-x64;
      nv-darwin-arm64 = nv.copilot-cli-darwin-arm64;
    };
    kiro-cli = import ./kiro-cli.nix {
      inherit inputs final;
      nv-linux-x64 = nv.kiro-cli-linux-x64;
      nv-darwin-arm64 = nv.kiro-cli-darwin-arm64;
    };
    kiro-gateway = import ./kiro-gateway.nix {
      inherit inputs final;
      nv = nv.kiro-gateway;
    };
  };

  # ── MCP servers ────────────────────────────────────────────────────
  # modelcontextprotocol/servers mono-repo packages (combined overlay).
  # Passes hashes + dummyHash so each sub-package can look up its own
  # dep hash by pname (the hash script writes per-flake-output keys).
  mcpMonoRepoDrvs = import ./mcp-servers/modelcontextprotocol-servers.nix {
    inherit inputs final hashes dummyHash;
    nv = nv.mcp-servers-mono;
  };

  mcpServerDrvs =
    mcpMonoRepoDrvs
    // {
      context7-mcp = import ./mcp-servers/context7-mcp.nix {
        inherit inputs final;
        nv = nv.context7-mcp;
      };
      effect-mcp = import ./mcp-servers/effect-mcp.nix {
        inherit inputs final;
        nv = nv.effect-mcp;
      };
      git-intel-mcp = import ./mcp-servers/git-intel-mcp.nix {
        inherit inputs final;
        nv = nv.git-intel-mcp;
      };
      github-mcp = import ./mcp-servers/github-mcp.nix {
        inherit inputs final;
        nv = nv.github-mcp;
      };
      kagi-mcp = import ./mcp-servers/kagi-mcp.nix {
        inherit inputs final;
        nv = nv.kagi-mcp;
      };
      mcp-language-server = import ./mcp-servers/mcp-language-server.nix {
        inherit inputs final;
        nv = nv.mcp-language-server;
      };
      mcp-proxy = import ./mcp-servers/mcp-proxy.nix {
        inherit inputs final;
        nv = nv.mcp-proxy;
      };
      nixos-mcp = import ./mcp-servers/nixos-mcp.nix {inherit inputs final;};
      openmemory-mcp = import ./mcp-servers/openmemory-mcp.nix {
        inherit inputs final;
        nv = nv.openmemory-mcp;
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
      nv = nv.git-absorb;
    };
    git-branchless = import ./git-tools/git-branchless.nix {
      inherit inputs final;
      nv = nv.git-branchless;
    };
    git-revise = import ./git-tools/git-revise.nix {
      inherit inputs final;
      nv = nv.git-revise;
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
