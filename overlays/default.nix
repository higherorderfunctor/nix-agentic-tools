# overlays/default.nix
# Unified binary-package overlay.
#
# Aggregates derivations exposed under pkgs.ai.* from individual
# overlays/<name>.nix files. Shared nvfetcher data comes from
# final.nv-sources (populated by nvSourcesOverlay in flake.nix),
# merged with sidecar hashes from ./hashes.json.
#
# Per-package files take custom argument sets (NOT uniform
# {nv-sources, ...} callers) because different packages have different
# needs — claude-code needs lockFile, kiro-cli needs nv-darwin, etc.
{inputs, ...}: final: prev: let
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: (final.nv-sources.${name} or {}) // (hashes.${name} or {});

  nv = {
    any-buddy = merge "any-buddy";
    claude-code = merge "claude-code";
    context7-mcp = merge "context7-mcp";
    copilot-cli = merge "github-copilot-cli"; # nvfetcher key
    effect-mcp = merge "effect-mcp";
    fetch-mcp = merge "mcp-server-fetch"; # nvfetcher key
    git-intel-mcp = merge "git-intel-mcp";
    git-mcp = merge "mcp-server-git"; # nvfetcher key
    github-mcp = merge "github-mcp-server"; # nvfetcher key
    kagi-mcp = merge "kagimcp"; # nvfetcher key
    kiro-cli = merge "kiro-cli";
    kiro-cli-darwin = merge "kiro-cli-darwin";
    kiro-gateway = merge "kiro-gateway";
    mcp-language-server = merge "mcp-language-server";
    mcp-proxy = merge "mcp-proxy";
    openmemory-mcp = merge "openmemory-mcp";
    sequential-thinking-mcp = merge "sequential-thinking-mcp";
    sympy-mcp = merge "sympy-mcp";
  };

  aiDrvs = {
    any-buddy = import ./any-buddy.nix {
      inherit inputs final;
      nv = nv.any-buddy;
    };
    claude-code = import ./claude-code.nix {
      inherit inputs final prev;
      nv = nv.claude-code;
      lockFile = ./locks/claude-code-package-lock.json;
    };
    context7-mcp = import ./context7-mcp.nix {
      inherit inputs final;
      nv = nv.context7-mcp;
    };
    copilot-cli = import ./copilot-cli.nix {
      inherit inputs final;
      nv = nv.copilot-cli;
    };
    effect-mcp = import ./effect-mcp.nix {
      inherit inputs final;
      nv = nv.effect-mcp;
    };
    fetch-mcp = import ./fetch-mcp.nix {
      inherit inputs final;
      nv = nv.fetch-mcp;
    };
    git-intel-mcp = import ./git-intel-mcp.nix {
      inherit inputs final;
      nv = nv.git-intel-mcp;
    };
    git-mcp = import ./git-mcp.nix {
      inherit inputs final;
      nv = nv.git-mcp;
    };
    github-mcp = import ./github-mcp.nix {
      inherit inputs final;
      nv = nv.github-mcp;
    };
    kagi-mcp = import ./kagi-mcp.nix {
      inherit inputs final;
      nv = nv.kagi-mcp;
    };
    kiro-cli = import ./kiro-cli.nix {
      inherit inputs final;
      nv = nv.kiro-cli;
      nv-darwin = nv.kiro-cli-darwin;
    };
    kiro-gateway = import ./kiro-gateway.nix {
      inherit inputs final;
      nv = nv.kiro-gateway;
    };
    mcp-language-server = import ./mcp-language-server.nix {
      inherit inputs final;
      nv = nv.mcp-language-server;
    };
    mcp-proxy = import ./mcp-proxy.nix {
      inherit inputs final;
      nv = nv.mcp-proxy;
    };
    nixos-mcp = import ./nixos-mcp.nix {inherit inputs final;};
    openmemory-mcp = import ./openmemory-mcp.nix {
      inherit inputs final;
      nv = nv.openmemory-mcp;
    };
    sequential-thinking-mcp = import ./sequential-thinking-mcp.nix {
      inherit inputs final;
      nv = nv.sequential-thinking-mcp;
    };
    serena-mcp = import ./serena-mcp.nix {inherit inputs final;};
    sympy-mcp = import ./sympy-mcp.nix {
      inherit inputs final;
      nv = nv.sympy-mcp;
    };
  };
in {
  ai = aiDrvs;
}
