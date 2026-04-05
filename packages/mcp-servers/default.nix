{inputs, ...}: final: prev: let
  # ── Sources ──────────────────────────────────────────────────────────
  # Merge nvfetcher generated sources with sidecar hashes
  sourcesOverlay = import ./sources.nix {} final prev;

  # Make nv-sources available for package files
  nv-sources = sourcesOverlay.nv-sources;

  # ── Package builder ──────────────────────────────────────────────────
  # Each file is a plain function: final -> derivation
  # Files that need flake inputs use the { inputs, ... }: final: pattern
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
  mcp-proxy = callPkg ./mcp-proxy.nix;
  nixos-mcp = callPkg ./nixos-mcp.nix;
  openmemory-mcp = callPkg ./openmemory-mcp.nix;
  sequential-thinking-mcp = callPkg ./sequential-thinking-mcp.nix;
  sympy-mcp = callPkg ./sympy-mcp.nix;
in {
  inherit nv-sources;

  nix-mcp-servers = {
    # Raw packages — upstream binaries as-is
    inherit
      context7-mcp
      effect-mcp
      fetch-mcp
      git-intel-mcp
      git-mcp
      github-mcp
      kagi-mcp
      mcp-proxy
      nixos-mcp
      openmemory-mcp
      sequential-thinking-mcp
      sympy-mcp
      ;
  };
}
