# `ai.proxy` → Claude Code: point Claude at a local CLIProxyAPI through its
# settings files, never through process env, which any settings `env` beats.
#
# The resolved endpoint (see lib/ai/proxy/default.nix) lands in
# `native.settings`, so the settings.json each backend already writes (user on
# Home Manager, project on devenv).
{
  lib,
  pkgs,
}: let
  # The endpoint as Claude settings. The url is the origin: Claude appends
  # `/v1/messages` itself. Every proxy writes BOTH key methods, the unused one
  # blank, because settings merge per key across scopes: a helper left in a
  # lower scope beside a token here (or the reverse) would send that other
  # key to this proxy too. `ANTHROPIC_API_KEY` is blanked, never set: an
  # interactive session asks before using a value, and declining sends the
  # claude.ai login instead; left unset, one inherited from the process env or
  # another scope rides along as `x-api-key`, an upstream credential sent to
  # the proxy.
  render = {
    key,
    url,
  }: {
    apiKeyHelper =
      if key ? file
      then "${pkgs.coreutils}/bin/cat ${lib.escapeShellArg key.file}"
      else key.helper or "";
    env = {
      ANTHROPIC_API_KEY = "";
      ANTHROPIC_AUTH_TOKEN = key.plain or "";
      ANTHROPIC_BASE_URL = url;
    };
  };

  # Without a proxy these reach api.anthropic.com and downloads.claude.ai
  # directly. Defaults, so a consumer can turn either back on.
  quietEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
  };
in {
  config = {resolvedProxy}:
    lib.mkMerge [
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings.env = lib.mapAttrs (_: lib.mkDefault) quietEnv;
      })
      # At ordinary priority: a consumer's own value for one of these leaves
      # is a definition conflict, not a silent override either way.
      (lib.mkIf (resolvedProxy ? endpoint) {
        ai.claude.native.settings = render resolvedProxy.endpoint;
      })
    ];
}
