# Cache-hit parity check — regression test that verifies
# overlay packages produce byte-identical store paths
# regardless of which nixpkgs a consumer brings. Drift means
# the overlay binds build inputs to the consumer's pkgs set,
# so cachix substituters (which serve paths built against
# this repo's pinned nixpkgs) won't match consumer requests.
#
# How the check works:
#   A) `self.packages.${system}.<pkg>` — built against
#      `inputs.nixpkgs` (this repo's pin). This is the path
#      CI pushes to nix-agentic-tools.cachix.org.
#   B) `consumerPkgs.<group>.<pkg>` — built against
#      `inputs.nixpkgs-test` (a deliberately different pin,
#      see flake.nix) with `self.overlays.default` applied.
#      This simulates what a consumer with a different
#      nixpkgs gets.
#
# If A == B for every package, the overlay successfully
# instantiates its own pkgs from `inputs.nixpkgs` instead of
# threading through the consumer's `final`/`prev`. If A != B
# for any package, that package will cache-miss for consumers.
#
# Mapping: flake.nix flattens the grouped overlay namespaces
# (pkgs.ai, pkgs.ai.mcpServers, pkgs.ai.lspServers, pkgs.gitTools)
# into top-level `self.packages.${system}.*` for CLI ergonomics.
# The consumer side keeps the grouped shape, so each package has
# a known source namespace we compare against.
{
  inputs,
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Simulate a consumer with a different nixpkgs pin. The
  # `nixpkgs-test` input deliberately tracks a different channel
  # from our primary `nixpkgs` input. Any overlay using `final.X`
  # for build inputs would close over THIS pkgs set instead of
  # our `inputs.nixpkgs`-instantiated one.
  consumerPkgs = import inputs.nixpkgs-test {
    inherit system;
    config.allowUnfree = true;
    overlays = [self.overlays.default];
  };

  # Each entry: { name, consumerPath } where consumerPath is a
  # dotted lookup under `consumerPkgs` that mirrors where the
  # overlay actually exposes the package to downstream users.
  #
  # Content-only packages (coding-standards, fragments-ai,
  # fragments-docs, stacked-workflows-content) are excluded — they
  # have no build inputs so their paths are already independent
  # of the consumer pin.
  #
  # Doc-site derivations (docs-*, instructions-*) are excluded —
  # they're produced by `flake.nix` itself, not the overlay, so
  # they don't exist on the consumer side.

  # AI CLIs — live at `consumerPkgs.ai.<name>`.
  aiCliPackages = [
    "claude-code"
    "copilot-cli"
    "kiro-cli"
    "kiro-gateway"
  ];

  # Git tools + agnix — live at `consumerPkgs.gitTools.<name>`
  # (git-absorb, git-revise).
  #
  # NOTE: `git-branchless` intentionally EXCLUDED. It consumes
  # `inputs.git-branchless.overlays.default final final` — an
  # upstream flake's overlay that binds to the consumer's pkgs
  # for base build inputs. Fixing this requires replacing the
  # thin upstream-overlay wrapper with a from-scratch nixpkgs
  # override using `ourPkgs`. Tracked as follow-up; see
  # overlays/git-tools/git-branchless.nix:21.
  gitToolPackages = [
    "git-absorb"
    "git-revise"
  ];

  # agnix + its mainProgram-override siblings.
  # agnix itself is at `consumerPkgs.ai.agnix` (flatDrvs entry).
  # agnix-lsp / agnix-mcp are at the lspServers / mcpServers
  # groups respectively.
  agnixPackages = [
    {
      name = "agnix";
      consumerLookup = p: p.ai.agnix;
    }
    {
      name = "agnix-lsp";
      consumerLookup = p: p.ai.lspServers.agnix-lsp;
    }
    {
      name = "agnix-mcp";
      consumerLookup = p: p.ai.mcpServers.agnix-mcp;
    }
  ];

  # MCP servers — live at `consumerPkgs.ai.mcpServers.<name>`.
  mcpServerPackages = [
    "context7-mcp"
    "effect-mcp"
    "git-intel-mcp"
    "github-mcp"
    "kagi-mcp"
    "mcp-language-server"
    "mcp-proxy"
    "nixos-mcp"
    "openmemory-mcp"
    "serena-mcp"
    "sympy-mcp"
  ];

  # Special entries — top-level names that don't match a grouped
  # attr path directly.
  specialPackages = [
    {
      # The modelcontextprotocol-all-mcps monorepo combined
      # package is surfaced at the top level but lives under
      # pkgs.ai.mcpServers.modelContextProtocol.all-mcps on the
      # grouped side.
      name = "modelcontextprotocol-all-mcps";
      consumerLookup = p: p.ai.mcpServers.modelContextProtocol.all-mcps;
    }
  ];

  # For packages wrapped by `ensureUnfreeCheck` (overlays/default.nix:guard),
  # the top-level outPath is a `final.symlinkJoin` of the real derivation.
  # The symlinkJoin is built by whichever pkgs set is doing the eval, so
  # its outPath naturally differs between our pin and the consumer pin.
  # But that wrapper is a small symlink farm — the heavy real build lives
  # at `drv.paths[0]`, which IS built from `ourPkgs` and must stay
  # byte-identical for cachix to serve consumers. Cache-hit parity
  # applies to the INNER path for wrapped derivations.
  realOutPath = drv:
    if drv ? paths && builtins.isList drv.paths && builtins.length drv.paths == 1
    then toString (builtins.head drv.paths)
    else drv.outPath;

  mkCheck = {
    name,
    consumerLookup,
  }: let
    standalone = realOutPath self.packages.${system}.${name};
    consumer = realOutPath (consumerLookup consumerPkgs);
  in
    if standalone == consumer
    then null
    else {inherit name standalone consumer;};

  aiCliChecks = map (name:
    mkCheck {
      inherit name;
      consumerLookup = p: p.ai.${name};
    })
  aiCliPackages;
  gitToolChecks = map (name:
    mkCheck {
      inherit name;
      consumerLookup = p: p.gitTools.${name};
    })
  gitToolPackages;
  agnixChecks = map mkCheck agnixPackages;
  mcpServerChecks = map (name:
    mkCheck {
      inherit name;
      consumerLookup = p: p.ai.mcpServers.${name};
    })
  mcpServerPackages;
  specialChecks = map mkCheck specialPackages;

  allDrifts = lib.filter (x: x != null) (
    aiCliChecks ++ gitToolChecks ++ agnixChecks ++ mcpServerChecks ++ specialChecks
  );
in {
  cache-hit-parity = pkgs.runCommand "cache-hit-parity" {} ''
    ${
      if allDrifts == []
      then "echo 'ok — no drift detected (every overlay package produces byte-identical store paths against both nixpkgs pins)' > $out"
      else let
        drifts = builtins.concatStringsSep "\n" (map (d: ''
            ${d.name}:
              standalone (inputs.nixpkgs):     ${d.standalone}
              consumer   (inputs.nixpkgs-test): ${d.consumer}
          '')
          allDrifts);
      in ''
        echo "FAIL: ${toString (builtins.length allDrifts)} package(s) bind build inputs to the consumer's nixpkgs and will NOT hit cachix:" >&2
        cat >&2 <<'DRIFT'
        ${drifts}
        DRIFT
        echo "" >&2
        echo "Each affected package must use 'ourPkgs = import inputs.nixpkgs { ... }'" >&2
        echo "instead of routing build inputs through the consumer-provided 'final'/'prev'." >&2
        echo "See .claude/rules/overlays.md 'Overlay Cache-Hit Parity' section for the full pattern." >&2
        exit 1
      ''
    }
  '';
}
