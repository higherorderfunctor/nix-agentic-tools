# Semble is deliberately re-exported from llm-agents.nix unchanged. Unlike the
# repo's locally built overlays, preserving this upstream derivation byte for
# byte is what lets both standalone and divergent-nixpkgs consumers substitute
# Numtide's pinned build (and the copy mirrored into this project's cache).
{
  inputs,
  final,
  ...
}:
inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.semble
