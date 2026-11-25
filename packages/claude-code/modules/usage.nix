# Claude contributes its packaged usage Reader to the shared Reader registry.
# delegate-routing reads the registry for its Claude usage technique command.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # This flake's build unless the overlay is applied (ai.internal.packages).
  aiPkgs = pkgs // {ai = config.ai.internal.packages;};
  reader = (import ../lib/default.nix).ai.claude-code.usageReader {
    pkgs = aiPkgs;
    inherit (config.ai.credentialUsage.readers.claude) cpa direct;
    inherit (aiPkgs.ai.generic) python-stack;
    # The Reader reads the version of the `claude` already on PATH, as the
    # Codex helper reads `codex`. Bundling this flake's CLI would put an unfree
    # package inside every delegate-routing skill.
    claude = pkgs.emptyDirectory;
  };
in {
  # The option exists wherever Claude's module is imported, including module
  # sets that list their modules by hand instead of discovering owners.
  imports = [(import ../../credential-usage/lib/default.nix).ai.credential-usage.readerModule];
  # Leaf defaults merge with other owners; an ordinary definition replaces one.
  config.ai.credentialUsage.readers.claude = lib.mapAttrs (_: lib.mkDefault) {
    package = reader;
    endpoint = "https://api.anthropic.com";
    transports = ["direct" "cpa"];
  };
}
