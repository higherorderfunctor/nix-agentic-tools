# MCP servers overlay — packages 14 Model Context Protocol servers
# under `pkgs.nix-mcp-servers.<name>`.
#
# 3-argument overlay shape (`{inputs, ...}: final: prev: ...`) per
# `dev/fragments/overlays/overlay-pattern.md`. The inputs blob is
# threaded into per-package overlays so each can instantiate its
# own `ourPkgs = import inputs.nixpkgs { ... }` for cache-hit
# parity (every build input routes through THIS repo's nixpkgs
# pin instead of the consumer's, so the published store paths
# stay byte-identical regardless of which nixpkgs the consumer
# brings).
#
# Per-package files use a single attrset destructuring arg with
# `nv-sources` injected from the local `nv-sources` binding (which
# is `final.nv-sources` merged with this directory's `hashes.json`
# sidecar values for `npmDepsHash`, `vendorHash`, `srcHash`, etc.
# that nvfetcher can't compute itself). Files that need flake
# inputs use the curried `{inputs, ...}: { nv-sources, ...}: ...`
# shape and `callPkg` routes them via `builtins.functionArgs`
# detection.
{inputs, ...}: final: _prev: let
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);

  # Read raw nvfetcher data from `final.nv-sources` (set by the
  # `nvSourcesOverlay` in `flake.nix` per the nix-standards rule)
  # and merge in this group's hashes.json sidecar values.
  nv-sources =
    builtins.mapAttrs (
      name: attrs: attrs // (hashes.${name} or {})
    )
    final.nv-sources;

  callPkg = path: let
    fn = import path;
    args = builtins.functionArgs fn;
  in
    if args ? inputs
    then fn {inherit inputs;} (final // {inherit nv-sources;})
    else fn (final // {inherit nv-sources;});

  # ── Raw packages ─────────────────────────────────────────────────────
  context7-mcp = callPkg ./context7-mcp.nix;
  effect-mcp = callPkg ./effect-mcp.nix;
  fetch-mcp = callPkg ./fetch-mcp.nix;
  git-intel-mcp = callPkg ./git-intel-mcp.nix;
  git-mcp = callPkg ./git-mcp.nix;
  github-mcp = callPkg ./github-mcp.nix;
  kagi-mcp = callPkg ./kagi-mcp.nix;
  mcp-language-server = callPkg ./mcp-language-server.nix;
  mcp-proxy = callPkg ./mcp-proxy.nix;
  nixos-mcp = callPkg ./nixos-mcp.nix;
  openmemory-mcp = callPkg ./openmemory-mcp.nix;
  sequential-thinking-mcp = callPkg ./sequential-thinking-mcp.nix;
  serena-mcp = callPkg ./serena-mcp.nix;
  sympy-mcp = callPkg ./sympy-mcp.nix;
in {
  nix-mcp-servers = {
    inherit
      context7-mcp
      effect-mcp
      fetch-mcp
      git-intel-mcp
      git-mcp
      github-mcp
      kagi-mcp
      mcp-language-server
      mcp-proxy
      nixos-mcp
      openmemory-mcp
      sequential-thinking-mcp
      serena-mcp
      sympy-mcp
      ;
  };
}
