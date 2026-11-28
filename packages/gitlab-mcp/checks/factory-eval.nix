# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  inherit (harness) checkRows mcpLib;
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
    factory-gitlab-mcp-settings = mkTest "gitlab-mcp-settings" (
      let
        defaultEnv = renderEnv {};
        instanceUrl = "https://gitlab.example.test/api/v4";
      in
        checkRows "GitLab MCP settings" {
          "disableVersionCheck defaults to suppressing the startup version check" = (defaultEnv.GITLAB_DISABLE_VERSION_CHECK or null) == "true";
          "disableVersionCheck false omits the variable instead of setting it" = !((renderEnv {disableVersionCheck = false;}) ? GITLAB_DISABLE_VERSION_CHECK);
          "instanceUrl omitted leaves the upstream endpoint default in effect" = !(defaultEnv ? GITLAB_API_URL);
          "instanceUrl set reaches the child environment as GITLAB_API_URL" = ((renderEnv {inherit instanceUrl;}).GITLAB_API_URL or null) == instanceUrl;
          # Reading only env does not force the PAT field used by the credentials wrapper.
          "pat remains a settings option with no implicit credential" = (mcpLib.evalSettings "gitlab-mcp" {}).pat == null;
        }
    );
  };
}
