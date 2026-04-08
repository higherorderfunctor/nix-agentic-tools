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
    claude-code = merge "claude-code";
  };

  aiDrvs = {
    claude-code = import ./claude-code.nix {
      inherit inputs final prev;
      nv = nv.claude-code;
      lockFile = ./locks/claude-code-package-lock.json;
    };
  };
in {
  ai = aiDrvs;
}
