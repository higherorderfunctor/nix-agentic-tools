# nvfetcher sources for AI CLI packages.
{final}: let
  generated = (import ../../.nvfetcher/generated.nix) {
    inherit (final) fetchgit fetchurl fetchFromGitHub dockerTools;
  };
in {
  copilot-cli = generated."github-copilot-cli";
  kiro-cli = generated."kiro-cli";
  kiro-gateway = generated."kiro-gateway";
}
