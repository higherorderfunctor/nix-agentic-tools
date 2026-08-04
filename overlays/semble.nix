# Semble is deliberately re-exported from llm-agents.nix unchanged. Unlike the
# repo's locally built overlays, preserving this upstream derivation byte for
# byte is what lets both standalone and divergent-nixpkgs consumers substitute
# Numtide's pinned build (and the copy mirrored into this project's cache).
{
  inputs,
  final,
  ...
}: let
  semble = inputs.llm-agents.packages.${final.stdenv.hostPlatform.system}.semble;
in
  semble
  // {
    passthru =
      (semble.passthru or {})
      // {
        # The update-target completeness check validates this input exists and
        # treats its normal flake-input bump as Semble's update owner. Plain
        # attrset extension preserves the upstream drvPath/outPath identity.
        updateFlakeInput = "llm-agents";
      };
  }
