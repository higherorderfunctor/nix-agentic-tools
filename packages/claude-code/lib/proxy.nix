# `ai.proxy` → Claude Code: point Claude at a local CLIProxyAPI through its
# settings files. Its launcher suppresses the inherited API-key descriptor
# before Claude caches it, ahead of applying settings env.
#
# The resolved endpoint (see lib/ai/proxy/default.nix) lands in
# `native.settings`, so the settings.json each backend already writes (user on
# Home Manager, project on devenv).
#
# Each routed upstream credential's models become `/model` picker rows; where each
# backend delivers them, and why, is in dev/fragments/ai-proxy/ai-proxy-runtimes.md.
{
  lib,
  pkgs,
}: let
  keyHelper = import ../../../lib/ai/proxy/key-helper.nix {inherit lib pkgs;};
  # Settings env overrides inherited API keys, bearer tokens and custom
  # headers, so a lower-scope credential cannot accompany the reference
  # resolved by apiKeyHelper, and inherited Bedrock, Vertex or Foundry
  # switches, which would send model traffic past the proxy.
  render = {
    owner ? "cliproxyapi",
    managedOauth ? false,
    key,
    url,
    ...
  }: let
    airlock = owner == "airlock";
    nativeOauth = airlock && managedOauth;
    helper =
      if airlock
      then null
      else
        keyHelper {
          inherit key;
          option = "ai.claude.proxy.key";
        };
  in {
    # An empty value clears a lower settings scope's CPA helper. Claude's
    # settings merge by key; null would omit the field and retain that helper.
    apiKeyHelper =
      if airlock
      then ""
      else lib.escapeShellArg (lib.getExe helper);
    env =
      {
        ANTHROPIC_API_KEY = "";
        ANTHROPIC_AUTH_TOKEN = "";
        ANTHROPIC_BASE_URL =
          if airlock
          then ""
          else url;
        ANTHROPIC_CUSTOM_HEADERS = "";
        CLAUDE_CODE_USE_BEDROCK = "";
        CLAUDE_CODE_USE_FOUNDRY = "";
        CLAUDE_CODE_USE_VERTEX = "";
      }
      // lib.optionalAttrs airlock {
        CLAUDE_CODE_OAUTH_TOKEN =
          if nativeOauth
          then ""
          else "airlock-fake-oauth-token-not-a-credential";
      };
  };

  # One row per authorized model comes from the resolved proxy contract. CPA
  # preserves route order; airlock's resolver sorts its declared IDs.
  pickerRows = resolvedProxy: let
    owner =
      if resolvedProxy == null
      then "cliproxyapi"
      else resolvedProxy.owner or "cliproxyapi";
  in
    lib.concatMap (credential:
      map (model: {
        description = "${credential.name} through ${
          if owner == "airlock"
          then "airlock"
          else "CLIProxyAPI"
        }";
        inherit model;
      })
      credential.models)
    (
      if resolvedProxy == null
      then []
      else resolvedProxy.credentials
    );

  # Without a proxy these reach api.anthropic.com and downloads.claude.ai
  # directly. Defaults, so a consumer can turn either back on.
  quietEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
  };
in {
  # Claude reads and caches this descriptor before applying settings env.
  # A settings-only blank therefore still leaks its key to the selected proxy.
  # devenv's picker rows travel as `--settings`, the one non-user scope a
  # project can reach; they replace any user `modelPicker` in that session,
  # since the highest scope that defines it wins outright.
  installPackage = {
    backend,
    cfg,
    resolvedProxy,
    ...
  }: let
    rows = pickerRows resolvedProxy;
    airlock = resolvedProxy != null && (resolvedProxy.owner or "cliproxyapi") == "airlock";
    nativeOauth = airlock && (resolvedProxy.managedOauth or false);
    # The explicit settings layer keeps route fields ahead of native settings
    # merges even when a different user directory is selected by the caller.
    # It contains only static fake credentials, never the CONNECT token.
    overlay = builtins.toFile "claude-proxy-settings.json" (builtins.toJSON (
      (lib.optionalAttrs airlock (render resolvedProxy))
      // lib.optionalAttrs (backend == "devenv" && rows != []) {modelPicker.options = rows;}
    ));
  in
    lib.ai.mkLauncher pkgs {
      exe = "claude";
      flags =
        lib.optional (resolvedProxy != null) "--unset CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
        ++ lib.optional nativeOauth "--unset CLAUDE_CODE_OAUTH_TOKEN"
        ++ lib.optional (airlock && backend == "hm") ''--run 'CLAUDE_CONFIG_DIR="''${HOME}/.claude"; export CLAUDE_CONFIG_DIR' ''
        ++ lib.optional airlock "--add-flags ${lib.escapeShellArg "--setting-sources ${
          if backend == "hm"
          then "user"
          else "project"
        }"}"
        ++ lib.optional (airlock || (backend == "devenv" && rows != [])) "--add-flags ${lib.escapeShellArg "--settings ${overlay}"}";
      name = "claude-code-proxy";
      inherit (cfg) package;
    };

  config = {
    backend,
    resolvedProxy,
  }:
    lib.mkMerge [
      (lib.mkIf (resolvedProxy != null && (resolvedProxy.owner or "cliproxyapi") != "airlock") {
        ai.claude.native.settings = {
          disableClaudeAiConnectors = lib.mkDefault true;
          env = lib.mapAttrs (_: lib.mkDefault) quietEnv;
        };
      })
      # At ordinary priority: a consumer's own value for one of these leaves
      # is a definition conflict, not a silent override either way.
      (lib.mkIf (resolvedProxy != null) {
        ai.claude.native.settings = render resolvedProxy;
      })
      (lib.mkIf (backend == "hm" && pickerRows resolvedProxy != []) {
        ai.claude.native.settings.modelPicker.options = pickerRows resolvedProxy;
      })
    ];
}
