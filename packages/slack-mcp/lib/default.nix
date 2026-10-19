{lib, ...}: let
  manifest = import ./manifest.nix {inherit lib;};
in {
  ai = {
    inherit (manifest) mkManifestApp mkManifestTask;
    mcpServers = {inherit (manifest) slackManifest;};
  };
}
