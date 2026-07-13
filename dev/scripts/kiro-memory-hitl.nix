# kiro-memory-hitl.nix — assemble a scratch `.kiro` config tree for the HITL
# live-TUI test of kiro-cli auto-memory (docs/plans/kiro-cli-auto-memory.md).
#
# Derives BOTH artifacts from the REAL generators so the harness cannot go stale:
#   - hooks:    packages/kiro-cli/lib/autoMemory.nix  (the exported generator)
#   - steering: lib/ai/transformers/kiro.nix          (the real frontmatter render)
# The one HITL-only substitution is `home = null` + a KIRO_MEMORY_DIR override, so
# the distiller reads the ambient (real) ~/.kiro/sessions but WRITES to a throwaway
# scratch dir — nothing lands in ~/.kiro config or ~/.kiro-memory.
#
# Built by dev/scripts/kiro-memory-hitl.sh. Uses `builtins.getFlake` only for the
# pinned `inputs.nixpkgs` (NOT the flake outputs), so it evaluates cheaply and does
# not trip the flake-eval OOM this repo's dev host hits. Requires `--impure`.
{memDir ? "/tmp/kiro-mem-hitl"}: let
  root = ../..;
  flake = builtins.getFlake (toString root);
  system = builtins.currentSystem;
  aiOverlay = import (root + "/overlays") {inherit (flake) inputs;};
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    overlays = [aiOverlay];
    config.allowUnfree = true;
  };
  inherit (pkgs) lib;

  mem = import (root + "/packages/kiro-cli/lib/autoMemory.nix") {
    inherit lib pkgs;
    home = null;
    env = {KIRO_MEMORY_DIR = memDir;};
  };

  kt = (import (root + "/lib/ai/transformers/kiro.nix") {inherit lib;}).kiroTransformer;
  rule = mem.rules."kiro-auto-memory";
  steering = kt.assemble {
    frontmatter = kt.frontmatter {
      inherit (rule) description paths;
      name = "kiro-auto-memory";
    };
    body = rule.text;
  };
in
  pkgs.runCommand "kiro-memory-hitl-config" {} ''
    mkdir -p "$out/hooks" "$out/steering"
    cp ${pkgs.writeText "kiro-memory.json" mem.hooks."kiro-memory"} "$out/hooks/kiro-memory.json"
    cp ${pkgs.writeText "kiro-auto-memory.md" steering} "$out/steering/kiro-auto-memory.md"
  ''
