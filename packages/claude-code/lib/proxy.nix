# `ai.proxy` → Claude Code: point Claude at a local CLIProxyAPI through its
# settings files. Its launcher suppresses the inherited API-key descriptor
# before Claude caches it, ahead of applying settings env.
#
# The resolved endpoint (see lib/ai/proxy/default.nix) lands in
# `native.settings`, so the settings.json each backend already writes (user on
# Home Manager, project on devenv).
{
  lib,
  pkgs,
}: let
  redact = import ../../../lib/redact {inherit lib;};
  # Settings env overrides inherited API keys, bearer tokens and custom
  # headers, so a lower-scope credential cannot accompany the reference
  # resolved by apiKeyHelper, and inherited Bedrock, Vertex or Foundry
  # switches, which would send model traffic past the proxy.
  render = {
    key,
    url,
  }: let
    helper = import ../../../lib/strict-shell-application.nix pkgs {
      name = "claude-proxy-key";
      text = ''
        # Reference paths and concat literals are already shell-escaped.
        # shellcheck disable=SC2016
        ${redact.assign {
          inherit pkgs;
          option = "ai.claude.proxy.key";
          value = key;
          variable = "key";
        }}
        printf '%s' "$key"
      '';
    };
  in {
    apiKeyHelper = lib.escapeShellArg (lib.getExe helper);
    env = {
      ANTHROPIC_API_KEY = "";
      ANTHROPIC_AUTH_TOKEN = "";
      ANTHROPIC_BASE_URL = url;
      ANTHROPIC_CUSTOM_HEADERS = "";
      CLAUDE_CODE_USE_BEDROCK = "";
      CLAUDE_CODE_USE_FOUNDRY = "";
      CLAUDE_CODE_USE_VERTEX = "";
    };
  };

  # Without a proxy these reach api.anthropic.com and downloads.claude.ai
  # directly. Defaults, so a consumer can turn either back on.
  quietEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
  };
in {
  # Claude reads and caches this descriptor before applying settings env.
  # A settings-only blank therefore still leaks its key to the selected proxy.
  installPackage = {
    cfg,
    resolvedProxy,
    ...
  }:
    lib.ai.mkLauncher pkgs {
      exe = "claude";
      flags = lib.optional (resolvedProxy != null) "--unset CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR";
      name = "claude-code-proxy";
      inherit (cfg) package;
    };

  config = {resolvedProxy}:
    lib.mkMerge [
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings.env = lib.mapAttrs (_: lib.mkDefault) quietEnv;
      })
      # At ordinary priority: a consumer's own value for one of these leaves
      # is a definition conflict, not a silent override either way.
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings = render resolvedProxy;
      })
    ];
}
