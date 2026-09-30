# Semble is deliberately re-exported from llm-agents.nix unchanged. Unlike the
# repo's locally built overlays, preserving this upstream derivation byte for
# byte is what lets both standalone and divergent-nixpkgs consumers substitute
# Numtide's pinned build (and the copy mirrored into this project's cache).
{
  inputs,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  semble = inputs.llm-agents.packages.${system}.semble;
in
  semble
  // {
    passthru =
      (semble.passthru or {})
      // {
        # Every llm-agents bump regenerates Semble's two snapshots from the
        # `passthru.extracted` of their drift checks, so the derivation above
        # stays untouched:
        #
        #   extracted.json           language knowledge (bundled grammars,
        #                            extension map, content-type sets)
        #   upstream-templates.json  agent templates, installer text, MCP surface
        #
        # The separate human-reviewed template hashes deliberately stay
        # untouched: CI must fail until a reviewer accepts or adapts each
        # local derivative after upstream content changes.
        regenerateExtracted = packageLib.mkRegenerateExtracted {
          name = "semble";
          inherit pkgs;
          targets = [
            {
              attr = "checks.${system}.semble-languages-extracted";
              dest = repoPath ../../../extracted.json;
            }
            {
              attr = "checks.${system}.semble-templates-extracted";
              dest = repoPath ../../../upstream-templates.json;
            }
          ];
        };
        # The update-target completeness check validates this input exists and
        # treats its normal flake-input bump as Semble's update owner. Plain
        # attrset extension preserves the upstream drvPath/outPath identity.
        updateFlakeInput = "llm-agents";
      };
  }
