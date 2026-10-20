# The Slack app manifest for the consumer's own app, derived from the evaluated
# `settings.manifest` of an `ai.mcpServers.slack-mcp` entry, and two printers that
# expose the file without installing anything: a flake app (`nix run`) and a
# devenv task. The manifest carries no url, token or client id.
{lib}: let
  inherit (import ../../../lib/mcp.nix {inherit lib;}) evalSettings;
  tools = import ./tools.nix {inherit lib;};

  printer = pkgs: file:
    import ../../../lib/strict-shell-application.nix pkgs {
      name = "print-${file.name}";
      runtimeInputs = [pkgs.coreutils];
      text = "cat ${file}";
    };
in {
  # A flake `apps.<system>.<name>` value printing `file`.
  mkManifestApp = pkgs: file: {
    type = "app";
    program = lib.getExe (printer pkgs file);
  };

  # A devenv `tasks.<name>` value printing `file`.
  mkManifestTask = pkgs: file: {
    description = "Print ${file.name}";
    exec = lib.getExe (printer pkgs file);
  };

  # `settings` is the entry's declared `settings` (for example
  # `config.ai.mcpServers.slack-mcp.settings`); the server module evaluates it,
  # so defaults and refusals match the rendered entry. The token is not read.
  slackManifest = {
    # Shown in the app directory and on the consent screen; at most 140
    # characters (Slack's limit). The default states what the selection
    # grants, so it stays true when `manifest.writes` changes.
    description ? null,
    name ? "Agent MCP",
    pkgs,
    settings,
  }: let
    selection = (evalSettings "slack-mcp" settings).manifest;
    grants =
      if selection.writes == []
      then "read-only"
      else "read-only except ${lib.concatStringsSep ", " selection.writes}";
    text =
      if description != null
      then description
      else "Personal MCP token acting as its user: ${grants}. The bot user never posts.";
    value = {
      display_information = {
        inherit name;
        description =
          if lib.stringLength text <= 140
          then text
          else throw "slackManifest: description is ${toString (lib.stringLength text)} characters; Slack allows 140";
      };
      # Slack requires a bot user on an app; the stub needs only `users:read`.
      features.bot_user = {
        always_online = false;
        display_name = name;
      };
      # `oauth_config.pkce_enabled` and `settings.is_mcp_enabled` are the PKCE
      # and MCP toggles (https://docs.slack.dev/reference/app-manifest.md,
      # fetched 2026-10-19); the docs pin carries only the MCP server page.
      oauth_config = {
        pkce_enabled = true;
        scopes = {
          bot = ["users:read"];
          user = tools.scopes selection;
        };
      };
      settings = {
        is_mcp_enabled = true;
        org_deploy_enabled = false;
        socket_mode_enabled = false;
        token_rotation_enabled = false;
      };
    };
  in
    ((pkgs.formats.yaml {}).generate "slack-mcp-manifest.yaml" value).overrideAttrs (old: {
      passthru = (old.passthru or {}) // {manifest = value;};
    });
}
