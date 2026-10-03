# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  # Renders through the package/typed-settings branch; the stand-in package
  # only has to be non-null, since settings resolve by server name.
  renderEnv = settings:
    (mcpLib.renderServer pkgs "gitlab-mcp" {
      package = pkgs.hello;
      inherit settings;
    })
    .env;
in {
  checks = {
    factory-loadServer-gitlab-mcp-from-package-dir = mkTest "loadServer-gitlab-mcp-from-package-dir" (
      let
        serverDef = mcpLib.loadServer "gitlab-mcp";
      in
        serverDef ? settingsOptions
        && serverDef.settingsOptions ? pat
    );

    factory-gitlab-mcp-has-package-module = mkTest "gitlab-mcp-has-package-module" (
      builtins.pathExists ../modules/mcp-server.nix
    );

    factory-gitlab-mcp-disable-version-check-default = mkTest "gitlab-mcp-disable-version-check-default" (
      (renderEnv {}).GITLAB_DISABLE_VERSION_CHECK or null == "true"
    );

    factory-gitlab-mcp-disable-version-check-false = mkTest "gitlab-mcp-disable-version-check-false" (!((renderEnv {disableVersionCheck = false;}) ? GITLAB_DISABLE_VERSION_CHECK));
  };
}
