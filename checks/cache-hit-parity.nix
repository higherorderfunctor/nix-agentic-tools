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
#   B) `consumerPkgs.<pkg>` — built against
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
# Phase 3.2-3.7 of docs/superpowers/plans/2026-04-08-architecture
# -foundation.md fix each affected overlay package. This check
# is the regression gate — landed in a failing state (TDD red),
# turns green when every package routes through `ourPkgs`.
{
  inputs,
  lib,
  pkgs,
  self,
}: let
  inherit (pkgs.stdenv.hostPlatform) system;

  # Simulate a consumer with a different nixpkgs pin. The
  # `nixpkgs-test` input is pinned to master (vs our primary
  # `nixpkgs` input on nixos-unstable). Any overlay using
  # `final.X` for build inputs will close over THIS pkgs set
  # instead of our `inputs.nixpkgs`-instantiated one.
  consumerPkgs = import inputs.nixpkgs-test {
    inherit system;
    config.allowUnfree = true;
    overlays = [self.overlays.default];
  };

  # Compiled packages exposed at the top level of
  # `self.packages.${system}`. Content-only packages
  # (coding-standards, fragments-ai, fragments-docs,
  # stacked-workflows-content) have no build inputs so their
  # paths are already independent of the consumer pin —
  # skip them.
  compiledPackages = [
    # git-tools
    "agnix"
    "git-absorb"
    "git-branchless"
    "git-revise"
    # ai-clis
    "claude-code"
    "github-copilot-cli"
    "kiro-cli"
    "kiro-gateway"
  ];

  # MCP servers re-exported at the top level of
  # `self.packages.${system}` but accessed via
  # `consumerPkgs.nix-mcp-servers.<name>` on the consumer side.
  mcpPackages = [
    "context7-mcp"
    "effect-mcp"
    "fetch-mcp"
    "git-intel-mcp"
    "git-mcp"
    "github-mcp"
    "kagi-mcp"
    "mcp-language-server"
    "mcp-proxy"
    "nixos-mcp"
    "openmemory-mcp"
    "sequential-thinking-mcp"
    "serena-mcp"
    "sympy-mcp"
  ];

  checkTopLevel = name: let
    standalone = self.packages.${system}.${name}.outPath;
    consumer = consumerPkgs.${name}.outPath;
  in
    if standalone == consumer
    then null
    else {inherit name standalone consumer;};

  checkMcp = name: let
    standalone = self.packages.${system}.${name}.outPath;
    consumer = consumerPkgs.nix-mcp-servers.${name}.outPath;
  in
    if standalone == consumer
    then null
    else {inherit name standalone consumer;};

  topLevelDrifts = lib.filter (x: x != null) (map checkTopLevel compiledPackages);
  mcpDrifts = lib.filter (x: x != null) (map checkMcp mcpPackages);
  allDrifts = topLevelDrifts ++ mcpDrifts;
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
        echo "See dev/notes/overlay-cache-hit-parity-fix.md for the full pattern." >&2
        exit 1
      ''
    }
  '';
}
