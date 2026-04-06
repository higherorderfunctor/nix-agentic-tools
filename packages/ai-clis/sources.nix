# nvfetcher sources for AI CLI packages.
{final}: let
  generated = (import ../../.nvfetcher/generated.nix) {
    inherit (final) fetchgit fetchurl fetchFromGitHub dockerTools;
  };
  hashes = builtins.fromJSON (builtins.readFile ./hashes.json);
  merge = name: attrs:
    attrs // (hashes.${name} or {});
in {
  claude-code = merge "claude-code" generated."claude-code";
  copilot-cli = generated."github-copilot-cli";
  kiro-cli = generated."kiro-cli";
  kiro-gateway = generated."kiro-gateway";
}
