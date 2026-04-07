# nvfetcher sources for AI CLI packages.
{final}: let
  generated = (import ../../.nvfetcher/generated.nix) {
    inherit (final) fetchgit fetchurl fetchFromGitHub dockerTools;
  };
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: attrs:
    attrs // (hashes.${name} or {});
in {
  any-buddy = generated."any-buddy";
  claude-code = merge "claude-code" generated."claude-code";
  copilot-cli = merge "github-copilot-cli" generated."github-copilot-cli";
  kiro-cli = generated."kiro-cli";
  kiro-cli-darwin = generated."kiro-cli-darwin";
  kiro-gateway = generated."kiro-gateway";
}
