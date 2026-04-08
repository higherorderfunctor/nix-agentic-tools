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
    kiro-cli = merge "kiro-cli";
    kiro-cli-darwin = merge "kiro-cli-darwin";
    kiro-gateway = merge "kiro-gateway";
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
    kiro-cli = import ./kiro-cli.nix {
      inherit inputs final;
      nv = nv.kiro-cli;
      nv-darwin = nv.kiro-cli-darwin;
    };
    kiro-gateway = import ./kiro-gateway.nix {
      inherit inputs final;
      nv = nv.kiro-gateway;
    };
  };
in {
  ai = aiDrvs;
}
